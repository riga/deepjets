from libcpp.string cimport string
from libcpp cimport bool

cdef extern from "Pythia8/Pythia.h" namespace "Pythia8":
    cdef cppclass Event:
        pass

    cdef cppclass Pythia:
        Event event
        Pythia(string, bool)
        bool readString(string)
        bool init()
        bool next()