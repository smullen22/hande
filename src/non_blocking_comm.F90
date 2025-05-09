module non_blocking_comm_m

! Core routines for initialisation and termination for non-blocking
! communication QMC algorithm.

! Non-Blocking Communications
! ===========================
!
! The cost of MPI communication soon becomes the biggest overhead when scaling a
! code to thousands of cores. Non-blocking communications (NBCs) can potentially
! reduce or eliminate this overhead if the communication operation is overlapped
! with computation. NBCs have been shown to help both strong (scaling the same
! problem size to more processors) and weak (increasing the problem size in
! proportion to the increase in processor count) scaling in the QMC code CASINO.
! Implementing them for FCIQMC is slightly tricky, as while annihilation is not
! necessary at every time step (see continuous time algorithm), it is vital that
! psips are annihilated at the same point in time.
!
! The general outline of the algorithm is the following:
!
! 1. Evolve the main list to time t + dt.
! 2. Receive walkers spawned during the previous iteration's evolution of the
!    main list into a second spawn_t type object (received_list).
! 3. We now need to evolve this received list one time step so that they can be
!    annihilated with the main list (evolve_spawned_walkers).
! 4. Annihilation then proceeds by annihilating the entirety of the received_list
!    and the portion of the spawned list which contains all walkers spawned from the
!    current processor onto the current processor in this iteration. This
!    includes walkers spawned from the received_list and the main list.
! 5. We then perform a non-blocking send operation of the walkers in the spawned
!    list to their new processors which will be received and evolved as in step
!    2 above.
!
! Starting NB calculation requires us to initially send / receive zero walkers
! so that step 2 above can be carried out without a special case in the first
! iteration.
!
! The staggered nature of events complicates certain things such as restarting
! a calculation and the reporting of report loop quantities.
! To avoid blocking mpi calls in between non-blocking sends/receives (which
! would happen during a report loop), we also use NBCs. This means
! that we print out the nth report loop's information when we usually would have
! printed the (n+1)st. It also means that the shift we use when evolving from
! step t to t + mc_steps*dt is based on total populations from the previous
! report loop.
! These above features also complicate the restarting of a calculation, as the
! shift required for the first iteration is not what would normally be printed
! out in the restart file. Currently only calculations restarted from
! one which used NBCs behave correctly as the shift is generally
! incorrect otherwise.
!
! Currently point-to-point nbcs are used as collective nbcs have only
! recently been added to the MPI standard (3.0) and which is not widely
! implemented by vendors.

implicit none

contains

    subroutine init_non_blocking_comm(qs, request, send_counts, ncycles, restart, restart_proj_est)

        ! Deal with initial send of data when using non-blocking communications.

        ! In/Out:
        !    qs: qmc_state_t object. On output the spawn store caches are updated (in particular,
        !        spawn_store%spawn now holds the set of particles from the previous calculation
        !        that need to be evolved one timestep) and the spawn and estimator communications
        !        are initialised.
        ! Out:
        !    request: array of requests for non-blocking communications
        !    send_counts: number of elements to send from each processor
        ! In:
        !    restart: doing a restart calculation or not.
        !    restart_proj_est: true if the projected estimator quantities were saved or re-estimated
        !        based on the restarted particle distribution.

        use const, only: p
        use parallel, only: iproc, nthreads, parent
        use energy_evaluation, only: local_energy_estimators, update_energy_estimators_send
        use qmc_data, only: qmc_state_t
        use spawn_data, only: non_blocking_send

        type(qmc_state_t), intent(inout) :: qs
        integer, intent(out) :: request(0:), send_counts(0:)
        integer, intent(in) :: ncycles
        logical, intent(in) :: restart, restart_proj_est

        integer :: start, nspawn

        send_counts = 0

        if (restart) then
            associate(spawn=>qs%spawn_store%spawn, restart_list=>qs%spawn_store%spawn_recv)
                start = spawn%head_start(0,iproc) + nthreads
                nspawn = restart_list%head(0,0)
                send_counts(iproc) = restart_list%head(0,0)
                spawn%sdata(:,start:start+nspawn) = restart_list%sdata(:,:nspawn)
            end associate
        end if

        call non_blocking_send(qs%spawn_store%spawn, send_counts, request)

        ! The output in non-blocking comms is delayed one report loop, so initialise
        ! the send here.
        ! For simplicity, hook into the normal estimator communications, which normalises
        ! by the number of MC cycles in a report loop (hence need to rescale to fake it).
        if (restart .and. .not.restart_proj_est .and. .not.parent) then
            ! If we stored the projected quantities, we know them exactly on each processor but still want to sum over all
            ! processors in order to easily initialise the non-blocking comms. Set all processors bar 1 to zero.
            qs%estimators%D0_population = 0.0_p
            qs%estimators%proj_energy = 0.0_p
        end if
        qs%estimators%D0_population = qs%estimators%D0_population*ncycles
        qs%estimators%proj_energy = qs%estimators%proj_energy*ncycles
        associate(spawn_elsewhere=>send_counts(iproc)/qs%spawn_store%spawn_recv%element_len)
            call local_energy_estimators(qs, qs%par_info%report_comm%rep_info, spawn_elsewhere=spawn_elsewhere)
        end associate
        call update_energy_estimators_send(qs%par_info%report_comm)

    end subroutine init_non_blocking_comm

    subroutine end_non_blocking_comm(sys, rng, qmc_in, annihilation_flags, ireport, qs, spawn, request_s, &
                                     request_rep, report_time, ntot_particles, shift, dump_restart_file, load_bal_in)

        ! Subroutine dealing with the last iteration when using non-blocking communications.

        ! Need to deal with:
        ! 1. Final send of walkers from time step T_final.
        ! 2. Final send of report loop quantites.

        ! In:
        !    sys: system being studied.
        !    qmc_in: input options relating to QMC methods.
        !    qs%ref: current qs%ref determinant.
        !    annihilation_flags: calculation specific annihilation flags.
        !    ireport: index of current report loop.
        !    dump_restart_file: if true then output an HDF5 restart file.
        !    load_bal_in: input options for load balancing.
        ! In/Out:
        !    rng: random number generator.
        !    qs: qmc_state_t object.
        !    spawn: spawn_t object containing spawned walkers from final
        !        iteration.
        !    request_s: array of requests for completing this final send of
        !        walkers.
        !    request_rep: array of requests for completing communication of
        !        report loop quantitites.
        !    report_time: time at the start of the current report loop.  Returns
        !        the current time (ie the time for the start of the next report
        !        loop.
        !    ntot_particles: total number of particles in main walker list.
        !    shift: current shift value.


        use annihilation, only: annihilate_main_list_wrapper
        use spawn_data, only: spawn_t, non_blocking_send, receive_spawned_walkers, &
                              annihilate_wrapper_non_blocking_spawn
        use energy_evaluation, only: update_energy_estimators_recv
        use system, only: sys_t
        use qmc_io, only: write_qmc_report
        use parallel, only: parent
        use qmc_data, only: qmc_in_t, load_bal_in_t, annihilation_flags_t, qmc_state_t

        use const, only: p, dp
        use dSFMT_interface, only: dSFMT_t

        type(sys_t), intent(in) :: sys
        type(qmc_in_t), intent(in) :: qmc_in
        type(qmc_state_t), intent(inout) :: qs
        type(annihilation_flags_t), intent(in) :: annihilation_flags
        type(dSFMT_t), intent(inout) :: rng
        integer, intent(in) :: ireport
        type(spawn_t), intent(inout) :: spawn
        integer, intent(inout) :: request_s(:), request_rep(:)
        real, intent(inout) :: report_time
        real(dp), intent(inout) :: ntot_particles(:)
        real(p), intent(inout) :: shift
        logical, intent(in) :: dump_restart_file
        type(load_bal_in_t), intent(in) :: load_bal_in

        real :: curr_time
        real(p) :: shift_save
        real(dp) :: ntot_particles_save(size(ntot_particles))

        call cpu_time(curr_time)

        ! Need to receive walkers sent from final iteration and merge into main list.
        call receive_spawned_walkers(spawn, request_s)
        if (.not. dump_restart_file) then
            call annihilate_wrapper_non_blocking_spawn(spawn, annihilation_flags%initiator_approx, qs%psip_list%descending)
            call annihilate_main_list_wrapper(sys, rng, qs%ref, annihilation_flags, qs%psip_list, spawn)
            ! Receive final send of report loop quantities.
        end if
        ntot_particles_save = ntot_particles
        shift_save = shift
        call update_energy_estimators_recv(qmc_in, qs, request_rep, ntot_particles, qs%psip_list%nparticles_proc, load_bal_in)
        if (parent) call write_qmc_report(qmc_in, qs, ireport, ntot_particles, curr_time-report_time, .false., .true.)
        ! The call to update_energy_estimators updates the shift and ntot_particles.
        ! When restarting a calculation we actually need the old (before the call)
        ! values of these quantites to be written to the restart file, so reset
        ! them in this case.
        if (dump_restart_file) then
            ntot_particles = ntot_particles_save
            shift = shift_save
        end if

    end subroutine end_non_blocking_comm

end module non_blocking_comm_m
