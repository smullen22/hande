[DEFAULT]
include_f = -I $${HDF5_ROOT-/usr}/include
cppflags_opt = -DSINGLE_PRECISION

[main]
fc = gfortran
cc = gcc
cxx = g++
ld = gfortran
ldflags = -L ${HOME}/lib -L $${HDF5_ROOT-/usr}/lib -L/usr/local/lib
libs = -llapack -lblas -lstdc++ -lhdf5_fortran -lhdf5 -lz -luuid -llua -ldl
f90_module_flag = -J

[opt]
cppflags = %(cppflags_opt)s
fflags = %(include_f)s -O3 -mfpmath=sse -msse2
cflags = -O3 -mfpmath=sse -msse2
cxxflags = -O3 -mfpmath=sse -msse2

[dbg]
cppflags = %(cppflags_opt)s -DDEBUG
fflags = %(include_f)s -g -fbounds-check -Wall -Wextra -fbacktrace -mfpmath=sse -msse2
cflags = -g -Wall -Wextra -fbacktrace -mfpmath=sse -msse2
cxxflags = -g -Wall -Wextra -fbacktrace -mfpmath=sse -msse2
