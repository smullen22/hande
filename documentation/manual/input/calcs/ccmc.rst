.. _ccmc:

Coupled Cluster Monte Carlo
===========================

.. code-block:: lua

    ccmc {
        sys = system,
        qmc = { ... },
        ccmc = { ... },
        restart = { ... },
        reference = { ... },
        logging = { ... },
        output = { ... },
        blocking = { ... },
        qmc_state = qmc_state,
        psip_list = psip_list,
    }

Returns:
    a qmc_state object.

``ccmc`` performs a coupled cluster Monte Carlo (CCMC) calculation [Thom10]_ on a system.

Options
-------

``sys``
    type: system object.

    Required.

    The system on which to perform the calculation.  Must be created via a system
    function.
``qmc``
    type: lua table.

    Required.

    Further options that are common to all implemented QMC algorithms.  See
    :ref:`qmc_table`.
``ccmc``
    type: lua table.

    Required.

    Further options to control the CCMC algorithm.  See :ref:`ccmc_table`.
``restart``
    type: lua table.

    Optional.

    Further options to control restarting the calculation from a previous calculation.
    See :ref:`restart_table`.
``reference``
    type: lua table.

    Optional.

    Further options to select the reference state used.  See :ref:`reference_table`.
``logging``
    type: lua table.

    Optional.

    Further options to enable various logging outputs from a CCMC simulation. Only
    available when compiled in debug mode. See :ref:`logging_table` for information
    on current options.
``output``
    type: lua_table.

    Optional.

    Further options to enable direction of calculation output to a different file.
    See :ref:`output_table` for more information.
``blocking``
    type: lua table.

    Optional.

    Further options to switch on and control blocking on the fly. See :ref:`blocking_table`.
``qmc_state``
    type: qmc_state object.

    Optional.

    Output of a previous calculation to resume.

    .. warning::

        The qmc_state object must have been returned by a previous CCMC calculation.
        The validity of this is not checked.  The system must also be unchanged and
        must not have a different even selection setting. To switch between using
        even selection and not a written restart file must be used.

    .. warning::

        This destroys the qmc_state object and so it cannot be re-used in subsequent
        QMC calculations.
``psip_list``
    type: particle_t object.

    Optional.

    Output wavefunction of a previous calculation to initialise the current CCMC calculation. 
    Currently only the :ref:`mp1` calculation can generate a psip_list.

    .. warning::

        The contents of the psip_list directly writes over the initial CCMC wavefunction, so 
        make sure the settings that were used to generate it are identical with those provided 
        for the CCMC table, otherwise undefined behaviour may result. The easiest way to ensure this 
        is outlined in :ref:`mp1`.

.. _ccmc_table:

ccmc options
------------

``move_frequency``
    type: integer

    Optional.  Default: 5.

    Allow excitors to move processors every :math:`2^x` iterations, where :math:`x` is the
    value of ``move_frequency``, in order to allow all composite excitors to be correctly
    sampled.  Relevant only when performing CCMC with MPI parallelisation.  A large value
    may introduce a bias.  Modify with caution. Can be changed when restarting
    calculations (and/or when :ref:`redistributing restart files <utils>`) but may impose
    some initialisation overhead whilst excitors are reassigned to different processors.
``cluster_multispawn_threshold``
    type: float.

    Optional.  Default: :math:`2^{31}-1`.

    Set the maximum value of :math:`A_C/p_C`, where :math:`A_C` is the cluster amplitude
    and :math:`p_C` is the probability of selecting the cluster.  A cluster with a value
    above this is split into multiple spawning attempts.  The default value essentially
    disables this but a smaller option can substantially reduce population blooms, albeit
    potentially at a significant computational cost.

    .. note::

        This is an experimental option and feedback is most welcome.  The current
        recommendation is to use the smallest setting such that large blooms do not occur.

``full_non_composite``
    type: boolean.

    Optional.  Default: false.

    If true, allow all non-composite clusters to attempt to spawn each iteration.  The
    original CCMC algorithm involves randomly selecting a cluster of arbitrary size
    consisting of any set of excitors and then making spawning attempts from it.  The full
    non-composite algorithm is a simple modification in which all occupied non-composite
    clusters (i.e. those consisting of the reference or just a single excitor) are
    (deterministically) selected and composite clusters (involving two or more excitors)
    are randomly selected to make spawning attempts.  This has been shown to give
    substantially more stable dynamics and reduce the plateau height in several systems.
``linked``
    type: boolean.

    Optional.  Default: false.

    If true, sample the linked coupled cluster equations instead of the unlinked coupled
    cluster equations [Franklin16]_.  The original CCMC algorithm solves the equations

    .. math::

        \langle D_m | \hat{H} - E | \psi_{CC} \rangle = 0.

    It is possible to instead sample the equivalent equations

    .. math::

        \langle D_m | e^{-\hat{T}} (\hat{H} - E) | \psi_{CC} \rangle = 0.

    Using the Hausdorff expansion of the Hamiltonian and the linked cluster theorem means 
    that the only clusters which contribute are those with at most four excitors and where 
    the excitation sampled from the Hamiltonian has an orbital in common with each excitor 
    in the cluster operator. Using this option can give substantial reductions in the 
    plateau height.
``vary_shift_reference``
    type: boolean.

    Optional.  Default: false.

    Vary the shift to keep the population at the reference, :math:`N_0`, constant, rather
    than the total population :math:`N_p`.  If ``target_population`` is below the plateau
    (or an equivalently low ``reference_target`` is specified) then, whilst the reference
    population will be controlled, the total population will continue to grow until a stable
    distribution is reached.
``density_matrices``
    type: boolean.

    Optional.  Default: false.

    Calculate the (unrelaxed) two-electron coupled cluster density matrix, given by:

    .. math::

        d_{PQRS} = \langle \psi_{HF} | P^{\dagger} R^{\dagger} S Q | \psi_{CC} \rangle
``density_matrix_file``
    type: string.

    Optional.  Default: 'RDM'.

    Filename to which the reduced density matrix is written.

``even_selection``
    type: boolean

    Optional. Default: false.

    If true, use selection probabilities for composite clusters such that the probability
    of selecting a cluster of any size is proportional to its contribution to the overall
    amplitude of the instantaneous wavefunction representation.

    .. TODO - guidance when to use this

    .. warning::

        This algorithm gives drastically different behaviour and is a subject of current
        research. As such, the situations in which this is the optimal approach are not yet
        entirely clear (benchmarking is underway). In addition, it is not currently confirmed
        to be compatible with propagation of the linked coupled cluster equations.

``multiref``
    type: boolean.

    Optional. Default: false.

    If true, perform a coupled cluster calculation using multiple references [Filip19]_. n_secondary_ref 
    and secondary_refX must then be defined.

``n_secondary_ref``
    type: integer.

    Optional. 

    Number of secondary references used. Must be in the range 1-999.
 
``secondary_refX``
    type: lua table.

    Describes the X-th secondary reference state used. See :ref:`reference_table`.
    Must include at least ``det`` and ``ex_level``. One table must be included for each
    secondary reference.
 
``mr_acceptance_search``
    type: string.

    Optional. Default: 'linear'.

    Possible values are 'linear' and 'bk_tree'.

    Specifies the acceptance algorithm for multireference excitation generation. 

    Linear search iterates through the list of ``secondary_refX`` provided and accepts a proposed excitation
    upon the first secondary reference that is within ``ex_level`` of it. This is more suitable for when ``n_secondary_ref``
    is small (:math:`<100`).

    BK tree search first builds a tree made of specified secondary references, and descends into the tree to search.
    A good explanation can be found `here <https://daniel-j-h.github.io/post/nearest-neighbors-in-metric-spaces/>`_.
    It should achieve sublinear time complexity, and the advantage over linear search will be more evident the larger the
    secondary reference space and the smaller the coupled cluster truncation (meaning a smaller subspace of the tree needs to be searched).

    .. note::

        The BK tree search algorithm is currently being benchmarked and optimised.

``mr_read_in``
    type: boolean.

    Whether to read in the secondary references from a file. If set to ``true``, then ``mr_secref_file`` must also be specified.

``mr_secref_file``
    type: string.

    The name of the file with the list of secondary references. Can be generated with ``tools/ccmc/generate_mr_input_file.py``, to see the available options, run

    .. code-block:: bash

        $ generate_mr_input_file.py -h

    When the ``compress`` flag is specified, only necessary references (those that are neccessary 
    to span the active space uniquely) are generated, without the flag every single determinant 
    in the active space is generated.

    The ``--nfrozen`` option is used to minimize the size of the ``secref`` file, where the frozen 
    core electrons are not included in the bitstrings, and instead the `mr_n_frozen` option is written into the Lua input file and 
    passed to HANDE, to be added back in when secondary references are initialised.

    The ``-l`` option is related to the size of the active space, such that a l-fold excitation 
    can reach the 'middle' determinant (for a :math:`(6e,6o)` active space for 
    nitrogen molecule, this would be a 
    three-fold excitation from the ground into all six orbitals being singly occupied 
    (:math:`M_s = 0` of course).

``mr_n_frozen``
    type: integer.

    Optional. Default: 0.

    Number of frozen core electrons, i.e., number of electrons that never move in the secondary references.

``mr_excit_lvl``
    type: integer.

    Required if ``mr_read_in`` is true.

    The excitation level allowable from every secondary reference.

    .. note::

        This essentially disables the ability to set excitation levels separately for each secondary reference.

``mr_secref_sym_only``
    type: boolean.

    Optional. Default: false.

    Whether to include only secondary references that belong to the symmetry sector specified in ``sys``.

    .. note::

        This is only compatible with ``mr_read_in`` being set to true.

``discard_threshold``
    type: float.

    Optional. Default: :math:`2^{31}-1`.

    The threshold of :math:`A_C/p_C`, where :math:`A_C` is the cluster amplitude
    and :math:`p_C` is the probability of selecting the cluster (exactly like ``cluster_multispawn_threshold``), 
    beyond which a cluster is discarded. This should be bigger than ``cluster_multispawn_threshold`` if both are specified. 
