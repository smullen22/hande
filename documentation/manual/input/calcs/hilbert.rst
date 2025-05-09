.. _hilbert:

Monte Carlo estimate of size of the Hilbert space
=================================================

Whilst calculating the size of an entire Hilbert space is straightforward via
combinatorics, calculating the size of a specific part of the Hilbert space meeting
a given set of quantum numbers (e.g. spin and symmetry) is more challenging.  Instead,
the size of this subspace can be estimated via a simple Monte Carlo approach [Booth10]_.

.. code-block:: lua

    hilbert_space {
        sys = system,
        hilbert = { ... },
        output = { ... },
    }

Returns:
    a table containing the mean (key: ``mean``) and associated standard
    error (key: ``std. err.``) of the Monte Carlo estimate of the size of
    the Hilbert space.

Options
-------

All options should be in the hilbert table bar the sys option.

``sys``
    type: system object.

    Required.

    The system on which to perform the calculation.  Must be created via a system
    function.
``hilbert``
    type: lua table.

    Required.

    Further options to control the Monte Carlo estimation of the Hilbert space.  See
    below.
``output``
    type: lua_table.

    Optional.

    Further options to enable direction of calculation output to a different file.
    See :ref:`output_table` for more information.

hilbert options
---------------

The ``hilbert`` table can take the following options:

``nattempts``
    type: integer.

    Required.

    Number of random attempts (i.e. the number of random determinants to generate) to
    perform per Monte Carlo cycle.
``ncycles``
    type: integer

    Optional.  Default: 20.

    Number of Monte Carlo cycles to perform.  Each cycle produces an independent estimate
    of the Hilbert space size.  Estimates of the mean and standard error are automatically
    calculated from each independent value.
``rng_seed``
    type: integer.

    Optional.  Default: generate a seed based upon the time and UUID (if available).

    Seed for initialising the random number generator.
``reference``
    type: vector of integers.

    Optional.  Default: attempt to make a good guess based upon the spin and symmetry
    quantum numbers of the system.

    The reference determinant as a list of occupied spin-orbitals.  The reference
    determinant is used in the generation of truncated Hilbert spaces only.
``ex_level``
    type: integer.

    Optional.  Default: set to the number of electrons in the system (i.e. generate the
    FCI space).

    Maximum excitation level to consider relative to the reference determinant.
