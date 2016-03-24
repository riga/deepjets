import tempfile

DTYPE = np.float64
ctypedef np.float64_t DTYPE_t
dtype_jet = np.dtype([('pT', DTYPE), ('eta', DTYPE), ('phi', DTYPE), ('mass', DTYPE)])
dtype_constit = np.dtype([('ET', DTYPE), ('eta', DTYPE), ('phi', DTYPE)])


cdef class GeneratorInput:
    cdef bool get_next_event(self) except *:
        return False
    
    cdef void to_pseudojet(self, vector[PseudoJet]& particles, float eta_max):
        pass

    cdef void to_delphes(self, Delphes* modular_delphes,
                         TObjArray* delphes_all_particles,
                         TObjArray* delphes_stable_particles,
                         TObjArray* delphes_partons):
        pass

    cdef void finish(self):
        pass


cdef class PythiaInput(GeneratorInput):
    cdef Pythia* pythia
    cdef int cut_on_pdgid
    cdef float pdgid_pt_min
    cdef float pdgid_pt_max

    def __cinit__(self, string config, string xmldoc,
                  int random_state=0, float beam_ecm=13000.,
                  int cut_on_pdgid=0,
                  float pdgid_pt_min=-1, float pdgid_pt_max=-1,
                  params_dict=None):
        self.pythia = new Pythia(xmldoc, False)
        self.pythia.readString("Init:showProcesses = on")
        self.pythia.readString("Init:showMultipartonInteractions = off")
        self.pythia.readString("Init:showChangedSettings = on")
        self.pythia.readString("Init:showChangedParticleData = off")
        self.pythia.readString("Next:numberShowInfo = 0")
        self.pythia.readString("Next:numberShowProcess = 0")
        self.pythia.readString("Next:numberShowEvent = 0")
        self.pythia.readFile(config)  # read user config after options above
        self.pythia.readString('Beams:eCM = {0}'.format(beam_ecm))
        self.pythia.readString('Random:setSeed = on')
        self.pythia.readString('Random:seed = {0}'.format(random_state))
        if params_dict is not None:
            for param, value in params_dict.items():
                self.pythia.readString('{0} = {1}'.format(param, value))
        self.pythia.init()
        self.cut_on_pdgid = cut_on_pdgid
        self.pdgid_pt_min = pdgid_pt_min
        self.pdgid_pt_max = pdgid_pt_max

    def __dealloc__(self):
        del self.pythia

    cdef bool get_next_event(self):
        # generate event and quit if failure
        if not self.pythia.next():
            raise RuntimeError("event generation aborted prematurely")
        
        if not keep_pythia_event(self.pythia.event, self.cut_on_pdgid,
                                 self.pdgid_pt_min, self.pdgid_pt_max):
            # event doesn't pass our truth-level cuts
            return False
        return True

    cdef void to_pseudojet(self, vector[PseudoJet]& particles, float eta_max):
        pythia_to_pseudojet(self.pythia.event, particles, eta_max)
        
    cdef void to_delphes(self, Delphes* modular_delphes,
                         TObjArray* delphes_all_particles,
                         TObjArray* delphes_stable_particles,
                         TObjArray* delphes_partons):
        # convert Pythia particles into Delphes candidates
        pythia_to_delphes(self.pythia.event, modular_delphes,
                          delphes_all_particles,
                          delphes_stable_particles,
                          delphes_partons)

    cdef void finish(self):
        self.pythia.stat()


cdef class HepMCInput(GeneratorInput):
    cdef IO_GenEvent* hepmc_reader
    cdef GenEvent* event

    def __cinit__(self, string filename):
        self.hepmc_reader = get_hepmc_reader(filename)

    def __dealloc__(self):
        del self.event
        del self.hepmc_reader

    cdef bool get_next_event(self):
        self.event = self.hepmc_reader.read_next_event()
        if self.event == NULL:
            return False
        return True

    cdef void to_pseudojet(self, vector[PseudoJet]& particles, float eta_max):
        hepmc_to_pseudojet(self.event[0], particles, eta_max)
        del self.event
        self.event = NULL


cdef class Jets:
    cdef readonly np.ndarray jets  # contains jet and trimmed jet
    cdef readonly np.ndarray subjets  # contains subjets (that sum to trimmed jet)
    cdef readonly np.ndarray constit  # contains original jet constituents
    cdef readonly np.ndarray trimmed_constit  # contains trimmed jet constituents
    cdef readonly float shrinkage
    cdef readonly float subjet_dr
    cdef readonly float tau_1
    cdef readonly float tau_2
    cdef readonly float tau_3


cdef void jets_from_result(Jets jets, Result* result):
    cdef int num_jet_constit
    cdef int num_subjets
    cdef int num_subjets_constit

    num_jet_constit = result.jet.constituents().size()
    num_subjets = result.subjets.size()
    num_subjets_constit = 0
    for isubjet in range(result.subjets.size()):
        num_subjets_constit += result.subjets[isubjet].constituents().size()
    
    jets.jets = np.empty((2,), dtype=dtype_jet)
    jets.subjets = np.empty((num_subjets,), dtype=dtype_jet)
    jets.constit = np.empty((num_jet_constit,), dtype=dtype_constit)
    jets.trimmed_constit = np.empty((num_subjets_constit,), dtype=dtype_constit)

    result_to_arrays(result[0],
                     <DTYPE_t*> jets.jets.data,
                     <DTYPE_t*> jets.subjets.data,
                     <DTYPE_t*> jets.constit.data,
                     <DTYPE_t*> jets.trimmed_constit.data)
    jets.shrinkage = result.shrinkage 
    jets.subjet_dr = result.subjet_dr
    jets.tau_1 = result.tau_1
    jets.tau_2 = result.tau_2
    jets.tau_3 = result.tau_3


@cython.boundscheck(False)
@cython.wraparound(False)
def generate_events(GeneratorInput gen_input,
                    int n_events,
                    float eta_max=5.,
                    float jet_size=0.6,
                    float subjet_size_fraction=0.5,
                    float subjet_pt_min_fraction=0.05,
                    float subjet_dr_min=0.,
                    float trimmed_pt_min=10., float trimmed_pt_max=-1., 
                    float trimmed_mass_min=-1., float trimmed_mass_max=-1.,
                    bool shrink=False, float shrink_mass=-1.,
                    bool compute_auxvars=False,
                    bool delphes=False,
                    string delphes_config='',
                    int delphes_random_state=0):
    """
    Generate events (or read HepMC) and yield jet and constituent arrays
    """
    if subjet_size_fraction <= 0 or subjet_size_fraction > 0.5:
        raise ValueError("subjet_size_fraction must be in the range (0, 0.5]")
    
    # Delphes init
    cdef ExRootConfReader* delphes_config_reader = NULL
    cdef Delphes* modular_delphes = NULL
    cdef TObjArray* delphes_all_particles = NULL
    cdef TObjArray* delphes_stable_particles = NULL
    cdef TObjArray* delphes_partons = NULL
    cdef TObjArray* delphes_input_array = NULL
    
    if delphes:
        delphes_config_reader = new ExRootConfReader()
        delphes_config_reader.ReadFile(delphes_config.c_str())
        # Set Delhes' random seed. Only possible through a config file...
        with tempfile.NamedTemporaryFile() as tmp:
            tmp.write("set RandomSeed {0:d}\n".format(delphes_random_state))
            tmp.flush()
            delphes_config_reader.ReadFile(tmp.name)
        modular_delphes = new Delphes("Delphes")
        modular_delphes.SetConfReader(delphes_config_reader)
        delphes_all_particles = modular_delphes.ExportArray("allParticles")
        delphes_stable_particles = modular_delphes.ExportArray("stableParticles")
        delphes_partons = modular_delphes.ExportArray("partons")
        modular_delphes.InitTask()
        delphes_input_array = modular_delphes.ImportArray("Calorimeter/towers")

    cdef int ievent;
    cdef Result* result
    cdef vector[PseudoJet] particles
    
    try:
        ievent = 0
        while ievent < n_events:
            if not gen_input.get_next_event():
                continue

            # convert generator output directly into pseudojets
            gen_input.to_pseudojet(particles, eta_max)

            # run jet clustering
            result = get_jets(particles,
                              jet_size, subjet_size_fraction,
                              subjet_pt_min_fraction,
                              subjet_dr_min,
                              trimmed_pt_min, trimmed_pt_max,
                              trimmed_mass_min, trimmed_mass_max,
                              shrink, shrink_mass,
                              compute_auxvars)

            if result == NULL:
                # didn't find any jets passing cuts in this event
                continue
            
            truth_jets = Jets()
            jets_from_result(truth_jets, result)
            del result

            if delphes:
                detector_jets = None
                modular_delphes.Clear()
                # convert generator particles into Delphes candidates
                gen_input.to_delphes(modular_delphes,
                                     delphes_all_particles,
                                     delphes_stable_particles,
                                     delphes_partons)
                # run Delphes reconstruction
                modular_delphes.ProcessTask()
                # convert Delphes reconstructed eflow candidates into pseudojets
                delphes_to_pseudojet(delphes_input_array, particles)

                # run jet clustering
                result = get_jets(particles,
                                  jet_size, subjet_size_fraction,
                                  subjet_pt_min_fraction,
                                  subjet_dr_min,
                                  trimmed_pt_min, trimmed_pt_max,
                                  trimmed_mass_min, trimmed_mass_max,
                                  shrink, shrink_mass,
                                  compute_auxvars)

                if result != NULL:
                    detector_jets = Jets()
                    jets_from_result(detector_jets, result)
                    del result

                yield truth_jets, detector_jets

            else:
                yield truth_jets
            ievent += 1
        gen_input.finish()
    finally:
        del modular_delphes
        del delphes_config_reader
