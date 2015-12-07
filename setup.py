#!/usr/bin/env python

from __future__ import print_function

try:
    import numpy as np
except ImportError:
    raise RuntimeError(
        "numpy cannot be imported. numpy must be installed "
        "prior to installing deepjets")

try:
    # try to use setuptools if installed
    from pkg_resources import parse_version, get_distribution
    from setuptools import setup, Extension
    if get_distribution('setuptools').parsed_version < parse_version('0.7'):
        # before merge with distribute
        raise ImportError
except ImportError:
    # fall back on distutils
    from distutils.core import setup
    from distutils.extension import Extension

import os
import sys
import subprocess
from glob import glob
from Cython.Build import cythonize

# Prevent setup from trying to create hard links
# which are not allowed on AFS between directories.
# This is a hack to force copying.
try:
    del os.link
except AttributeError:
    pass

local_path = os.path.dirname(os.path.abspath(__file__))
# setup.py can be called from outside the root_numpy directory
os.chdir(local_path)
sys.path.insert(0, local_path)

PYTHIADIR = os.environ['PYTHIADIR']
FASTJETDIR = os.environ['FASTJETDIR']

libdeepjets = Extension(
    'deepjets._libdeepjets',
    sources=['deepjets/src/_libdeepjets.pyx'],
    depends=['deepjets/src/deepjets.h'],
    language='c++',
    include_dirs=[
        np.get_include(),
        'deepjets/src',
        os.path.join(PYTHIADIR, 'include'),
        os.path.join(FASTJETDIR, 'include'),
    ],
    library_dirs=[
        os.path.join(PYTHIADIR, 'lib'),
        os.path.join(FASTJETDIR, 'lib'),
    ],
    libraries='pythia8 fastjet fastjetplugins boost_iostreams boost_thread CGAL gmp'.split(),
    extra_compile_args=[
        '-Wno-unused-function',
        '-Wno-write-strings',
    ])

setup(
    name='deepjets',
    version='0.0.1',
    packages=['deepjets'],
    ext_modules=cythonize([libdeepjets]),
)
