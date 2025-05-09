module load_balancing

! Module for performing load balancing for FCIQMC and i-FCIQMC calculations.

! Load balancing
! ==============

! In full configuration interaction (FCIQMC) and coupled cluster (CCMC) form of
! quantum Monte Carlo, the wavefunction is sampled by a set of particles across
! a discetized Hilbert space (the space of determinants/excitors).  We wish to
! distribute the particles such that the load balance across N_p processors is as
! even as possible.
!
! This is tricky: it is far more memory efficient to store the particles
! according to their location (as there can be, and usually is, a number of
! locations occupied by a large number of particles).  Further, the occupancy is
! rather sparse to naively dividing the Hilbert space evenly between processors
! according to (say) the determinant/excitor representation is not necessarily
! a good idea.  We are further hampered by the fact that we don't know anything
! a priori about the wavefunction.
!
! Hash-based load balancing
! -------------------------
!
! By default a determinant (with some representation D) is assigned to
! processor P out of N_p processors using a hash function:
!
! P = modulo(hash(D), N_p)
!
! If we assume:
!
! * the hash function gives a uniform distribution across processors
! * the random assignment of determinants to processors results in the a small
!    spread in total populations on each processor
!
! then this load balancing procedure will perform very well.
!
! In some cases these assumptions do not seem to hold.  How can we do better
! without (dramatically) increasing the cost?
!
! Flexible hash-based load balancing
! ----------------------------------------------
!
! First, let's generalise the above function:
!
! P = proc_map(modulo(hash(D), X*N_p))
!
! where X (load_balancing_slots) is an integer constant and proc_map is an X*N_p array.
! This is only slightly more expensive to compute (by 1 multiplication and 1 memory load).
!
! Let's start by initialising proc_map such that each processor index occurs
! X times (either uniformly, randomly or in some cyclic fashion).  (If X=1 and
! proc_map(i)=i, this is identical to the current procedure.)
!
! How does this help?  Well, let's consider a simulation where the load balancing
! not particularly uniform.  We can dynamically change proc_map, say by donating
! a slot from a processor with an above-average population to a processor with
! a below-average population.  Before the simulation can proceed, determinants on
! the above-average processors will need to be reassigned and (potentially) sent
! to their new location.
!
! Some comments:
!
! * one should not redistribute frequently, especially at the start of
!    a calculation.
! * after equilibriation, no further redistribution should be required and
!    the procedure described above should be extremely efficient.
! * Increasing X increases the flexibility but also the cost of determining the
!    load balancing.
! * This is not very smart load balancing: it does not give you control to force
!    each processor to have almost the same number of particles.  What it does do
!    is introduce just a little more flexibility into the algorithm (in the hope
!    that this will overcome the worst of the problems.
! * The proc_map can be stored in the restart file (especially useful if
!    restarting a calculation on the same number of processors).  Load balancing
!    should probably be performed at the start of a calculation if the population
!    is held constant.

use const , only: int_64, p, dp, int_p

implicit none

type dbin_t
    ! Number of bins we can donate from donor processors.
    integer :: nslots
    ! pop: array containing populations of donor slots which we try and redistribute
    !      to receiver processors. This is a reduced version of slot_list containing
    !      only slots corresponding to donor processors.
    real(p), allocatable :: pop(:)
    ! index: entries contains the original index of a donor bin in slot_list/proc_map.
    integer, allocatable :: index(:)
    ! rank: array containing indices which correspond to the ranked (lowest to highest)
    !       entries in pop array.
    integer, allocatable :: rank(:)
end type dbin_t


contains

    subroutine init_parallel_t(ntot_proc_data, ndata, non_blocking_comm, par_calc, nslots)

        ! Allocate and initialise a parallel_t object.

        ! In:
        !    ntot_proc_data: total number of data items that are gathered on a per processor (e.g.
        !        particles for each space and bloom stats).  This is the total quantity required to
        !        receive this from all processors (i.e. nprocs*per processor amount), as calculated
        !        in comm_processor_indx.
        !    ndata: the number of additional data elements accumulated over all
        !        processors (e.g. est_buf_data_size) .
        !    non_blocking_comm: true if using non-blocking communications
        !    nslots: number of slots we divide proc_map into
        ! In/Out:
        !    par_calc: type containing parallel information for calculation
        !        see definitions above.

        use parallel, only: nprocs
        use checking, only: check_allocate
        use qmc_data, only: parallel_t

        integer, intent(in) :: ntot_proc_data, ndata
        logical, intent(in) :: non_blocking_comm
        integer, intent(in) :: nslots
        type(parallel_t), intent(inout) :: par_calc

        integer :: ierr

        associate(nb=>par_calc%report_comm)
            if (non_blocking_comm) then
                allocate(nb%rep_info(ntot_proc_data+ndata), stat=ierr)
                call check_allocate('nb%rep_info', ntot_proc_data+ndata, ierr)
                allocate(nb%request(0:nprocs-1), stat=ierr)
                call check_allocate('nb%request', nprocs, ierr)
            end if
        end associate

        call init_proc_map_t(nslots, par_calc%load%proc_map)

    end subroutine init_parallel_t

    subroutine init_proc_map_t(nslots, pm, np)

        ! In:
        !    nslots: number of slots (per processor) we divide proc_map_t into.
        !    np (optional): number of proecssors to use for the processor map.
        !       Default: nprocs (number of processors calculation is being run on).
        ! In/Out:
        !    pm: proc_map_t object containing a mapping of slot to processor index.

        use checking, only: check_allocate

        use parallel, only: nprocs
        use spawn_data, only: proc_map_t

        integer, intent(in) :: nslots
        type(proc_map_t), intent(out) :: pm
        integer, intent(in), optional :: np

        integer :: i, ierr, pm_np

        if (present(np)) then
            pm_np = np
        else
            pm_np = nprocs
        end if

        pm%nslots = nslots
        allocate(pm%map(0:nslots*pm_np-1), stat=ierr)
        call check_allocate('pm%map', nslots*pm_np, ierr)
        forall (i=0:nslots*pm_np-1) pm%map(i) = modulo(i,pm_np)

    end subroutine init_proc_map_t

    subroutine dealloc_parallel_t(par_calc)

        ! Deallocate parallel_t object.

        ! In/Out:
        !    par_calc: type containing parallel information for calculation
        !        see definitions above.

        use checking, only: check_deallocate
        use qmc_data, only: parallel_t

        type(parallel_t), intent(inout) :: par_calc

        integer :: ierr

        associate(nb=>par_calc%report_comm)
            if (allocated(nb%rep_info)) then
                deallocate(nb%rep_info, stat=ierr)
                call check_deallocate('nb%rep_info', ierr)
            end if
            if (allocated(nb%request)) then
                deallocate(nb%request, stat=ierr)
                call check_deallocate('nb%request', ierr)
            end if
        end associate

        associate(proc_map=>par_calc%load%proc_map)
            if (allocated(proc_map%map)) then
                deallocate(proc_map%map, stat=ierr)
                call check_deallocate('proc_map%map', ierr)
            end if
        end associate

    end subroutine dealloc_parallel_t

    subroutine do_load_balancing(psip_list, spawn, parallel_info, load_bal_in)

        ! Main subroutine in module, carries out load balancing as follows:
        ! 1. If doing load balancing then:
        !   * Find processors which have above/below average population.
        !   * For processors with above average populations enter slots from slot_list
        !     into smaller array which is then ranked according to population.
        !   * Attempt to move these slots to processors with below average population.
        ! 2. Once proc_map is modified so that its entries contain the new locations
        !   of of donor slots, we then add these determinants to spawned walker list so
        !   that they can be moved to their new processor.

        ! In:
        !    load_bal_in: number of load balancing slots.
        ! In/Out:
        !    parallel_info: parallel_t type object containing information for
        !       parallel calculation.  See qmc_calc.f90 for description.  Updated
        !       on exit with the new processor map.
        !    psip_list: psip locations and populations.  On output
        !       nparticles_proc (number of particles on each processor) is updated.
        !    spawn: spawn_t object which defines processor locations of particles.
        !       Its copy of proc_map (spawn%proc_map) is updated on exit to match
        !       that in parallel_info.

        use parallel
        use spawn_data, only: spawn_t
        use ranking, only: insertion_rank
        use checking, only: check_allocate, check_deallocate
        use qmc_data, only: load_bal_in_t, particle_t, parallel_t

        type(particle_t), intent(inout) :: psip_list
        type(parallel_t), intent(inout) :: parallel_info
        type(spawn_t), intent(inout) :: spawn
        type(load_bal_in_t), intent(in) :: load_bal_in

        real(p) :: slot_pop(0:size(parallel_info%load%proc_map%map)-1)
        real(p) :: slot_list(0:size(parallel_info%load%proc_map%map)-1)

        integer, allocatable :: donors(:), receivers(:)
        type(dbin_t) :: donor_bins

        integer :: i, ierr
        real(p) :: pop_av, up_thresh, low_thresh

        slot_list = 0.0_dp

        associate(lb=>parallel_info%load, proc_map=>parallel_info%load%proc_map)

        ! Find slot populations.
        call initialise_slot_pop(psip_list, spawn, slot_pop)
#ifdef PARALLEL
        ! Gather slot populations from every process into slot_list.
        call MPI_AllReduce(slot_pop, slot_list, size(slot_pop), MPI_PREAL, MPI_SUM, MPI_COMM_WORLD, ierr)
#endif
        ! Whether load balancing is required or not is decided based on the
        ! populations across processors during the report loop. For non-blocking
        ! communications the report loop populations relate to the previous
        ! report loop's populations due to the staggered nature how the report
        ! loop is dealt with. This shouldn't be an issue as an imblanace should
        ! persist between report loops, but best to base redistribution on
        ! current populations, so update these here. When not using non-blocking
        ! comms then the population before this evalutation should be the same
        ! as those after.
        ! Note: these populations are calculated from the main list and do not
        ! include walkers in the received list which have not been introduced
        ! yet.
        forall (i=1:nprocs) psip_list%nparticles_proc(1,i) = sum(slot_list, MASK=proc_map%map==i-1)
        pop_av = real(sum(psip_list%nparticles_proc(1,:nprocs))/nprocs,p)

        ! As stated above we only initially determine when to do load balancing
        ! based on the previous report loop's populations. This means that the
        ! first report loop after the first load balancing attempt won't have
        ! taken this first load balancing into account. As a result the decision
        ! to attempt load balancing will be a bad one, so we potentially need to
        ! exit the subroutine now.
        call check_imbalance(real(psip_list%nparticles_proc,p), pop_av, load_bal_in%percent, lb%needed)
        if (.not. lb%needed) return

        up_thresh = pop_av + int(pop_av*load_bal_in%percent)
        low_thresh = pop_av - int(pop_av*load_bal_in%percent)

        ! Find donor/receiver processors.
        call find_processors(real(psip_list%nparticles_proc(1,:nprocs),p), up_thresh, low_thresh, &
                             proc_map%map, receivers, donors, donor_bins%nslots)

        ! Smaller list of donor slot populations.
        call alloc_dbin_t(donor_bins)

        ! Put donor slots into array so we can sort them.
        call reduce_slots(donors, slot_list, proc_map%map, donor_bins%index, donor_bins%pop)
        call insertion_rank(donor_bins%pop, donor_bins%rank, 1.0e-8_p)

        if (load_bal_in%write_info .and. parent) &
            call write_load_balancing_info(real(psip_list%nparticles_proc,p), donor_bins%pop)

        ! Attempt to modify proc map to get more even population distribution.
        call redistribute_slots(donor_bins, receivers, up_thresh, low_thresh, proc_map%map, &
                                psip_list%nparticles_proc(1,:nprocs))
        lb%nattempts = lb%nattempts + 1

        ! Update spawn%proc_map with the 'master' version.
        spawn%proc_map = parallel_info%load%proc_map

        if (load_bal_in%write_info .and. parent) &
            call write_load_balancing_info(real(psip_list%nparticles_proc,p), donor_bins%pop)

        deallocate(donors, stat=ierr)
        call check_deallocate('donors', ierr)
        deallocate(receivers, stat=ierr)
        call check_deallocate('receivers', ierr)
        call dealloc_dbin_t(donor_bins)

        end associate

    end subroutine do_load_balancing

    subroutine write_load_balancing_info(nparticles_proc, d_slot_pop)

        ! Write out information about the most and least heavily populated
        ! processor. Also write out the smallest available slot we can donate,
        ! which is useful to see why load balancing can't occur i.e. if the
        ! percentage imbalance needs to be lowered.

        ! In:
        !    nparticles_proc: array containing population of walkers on each
        !       processor.
        !    d_slot_pop: populations of donor slots contained in proc_map.

        use parallel, only: nprocs

        real(p), intent(in) :: nparticles_proc(:,:), d_slot_pop(:)
        integer :: iunit

        iunit = 6

        write (iunit, '(1X, "#",2X,"Load balancing info:")')
        write (iunit, '(1X, "# ",1X,a18,2X,a18,2X,a22,2X,a12,9X,a12)') "Max # of particles", "Min # of particles", &
                  "Average # of particles", "Max slot pop", "Min slot pop"
        write (iunit, '(1X, "#",1X,3(es17.10,3X),4X,es17.10,4X,es17.10)') maxval(nparticles_proc(1,:)), &
                  minval(nparticles_proc(1,:)), sum(nparticles_proc(1,:))/nprocs, &
                  maxval(d_slot_pop), minval(d_slot_pop)

    end subroutine write_load_balancing_info

    subroutine check_imbalance(nparticles_proc, average_pop, percent_imbal, load_tag)

        ! Check if there is at least one imbalanced processor.

        ! In:
        !    nparticles_proc: population of walkers across all processors.
        !    average_pop: average population across all processors.
        !    percent_imbal: desired percentage load imbalance.
        ! Out:
        !    load_tag: set to .true. if load balancing is required
        !        else set to .false..

        use parallel, only: nprocs

        real(p), intent(in) :: nparticles_proc(:,:), average_pop
        real(p), intent(in) :: percent_imbal
        logical, intent(out) :: load_tag

        real(dp) :: upper_threshold

        upper_threshold = average_pop + average_pop*percent_imbal

        if (any(nparticles_proc(1,:nprocs) > upper_threshold)) then
            load_tag = .true.
        else
            load_tag = .false.
        end if

    end subroutine check_imbalance

    subroutine alloc_dbin_t(donor_slots)

        ! Allocate dslot type.

        ! In/Out:
        !     donor_slots: type containing population and position in
        !         proc_map of bins of walkers which we are attempting
        !         to redistribute. Also contains ranked version of donor
        !         bins.

        use checking, only: check_allocate

        type(dbin_t), intent(inout) :: donor_slots

        integer :: ierr

        allocate(donor_slots%pop(donor_slots%nslots), stat=ierr)
        call check_allocate('donor_slots%pop', donor_slots%nslots, ierr)
        ! Contains ranked version of d_slot_pop.
        allocate(donor_slots%rank(donor_slots%nslots), stat=ierr)
        call check_allocate('donor_slots%rank', donor_slots%nslots, ierr)
        ! Contains index in proc_map of donor slots.
        allocate(donor_slots%index(donor_slots%nslots), stat=ierr)
        call check_allocate('donor_slots%index', donor_slots%nslots, ierr)

    end subroutine alloc_dbin_t

    subroutine dealloc_dbin_t(donor_slots)

        ! Deallocate d_slot type.

        ! In/Out:
        !     donor_slots: type containing population and position in
        !         proc_map of bins of walkers which we are attempting
        !         to redistribute. Also contains ranked version of donor
        !         bins.

        use checking, only: check_deallocate

        type(dbin_t), intent(inout) :: donor_slots

        integer :: ierr

        deallocate(donor_slots%pop, stat=ierr)
        call check_deallocate('donor_slots%pop', ierr)
        deallocate(donor_slots%rank, stat=ierr)
        call check_deallocate('donor_slots%rank', ierr)
        deallocate(donor_slots%index, stat=ierr)
        call check_deallocate('donor_slots%index', ierr)

    end subroutine dealloc_dbin_t

    subroutine redistribute_slots(donor_bins, receivers, up_thresh, low_thresh, proc_map, procs_pop)

        ! Attempt to modify entries in proc_map to get a more even population distribution across processors.

        ! Slots from d_slot_pop are currently donated in increasing slot population.
        ! This is carried out while the donor processor's population is above a specified threshold
        ! or the receiver processor's population is below a certain threshold.

        ! In:
        !   donor_bins: type containing various information about bins of
        !       walkers we will attempt to distribute such as population and
        !       index in original proc_map array. See defintion of type for more
        !       details.
        !   receivers: array containing receiver processors
        !       (ones with above/below average population).
        !   up_thresh: Upper population threshold for load imbalance.
        !   low_thresh: lower population threshold for load imbalance.
        ! In/Out:
        !   proc_map: array which maps determinants to processors.
        !       proc_map(modulo(hash(d),load_balancing_slots*nprocs)) = processor.
        !   procs_pop: array containing populations on each processor.

        type(dbin_t) :: donor_bins
        integer, intent(in) :: receivers(:)
        real(p), intent(in) :: up_thresh, low_thresh
        real(dp), intent(inout) :: procs_pop(0:)
        integer, intent(inout) :: proc_map(0:)

        integer :: pos
        integer :: i, j
        real(dp) :: donor_pop, new_pop

        donor_pop = 0.0_dp
        new_pop = 0.0_dp

        do i = 1, size(donor_bins%pop)
            ! Loop over receivers.
            pos = donor_bins%rank(i)
            do j = 1, size(receivers)
                ! Try to add this to below average population.
                new_pop = donor_bins%pop(pos) + procs_pop(receivers(j))
                ! Modify donor population.
                donor_pop = procs_pop(proc_map(donor_bins%index(pos))) - donor_bins%pop(pos)
                ! If adding subtracting slot doesn't move processor pop past a bound.
                if (donor_pop .ge. low_thresh .and. new_pop .le. up_thresh)  then
                    ! Changing processor population.
                    procs_pop(proc_map(donor_bins%index(pos))) = donor_pop
                    procs_pop(receivers(j)) = new_pop
                    ! Updating proc_map.
                    proc_map(donor_bins%index(pos)) = receivers(j)
                    ! Leave the j loop, could be more than one receiver.
                    exit
                 end if
             end do
         end do

    end subroutine redistribute_slots

    subroutine reduce_slots(donors, slot_list, proc_map, d_slot_index, d_slot_pop)

        ! slot_list and proc_map are arrays of length load_balancing_slots*nprocs.
        ! Only interested in slots corresponding to the donor processors, so put
        ! these in smaller and more straightforwardly ordered array d_slot_pop, which can be sorted
        ! etc.

        ! In:
        !   donors: array containing donor processors.
        !   slot_list: array containing populations of slots across all processors.
        !   proc_map: array which maps determinants to processors.
        !       proc_map(modulo(hash(d),load_balancing_slots*nprocs))=processor.
        ! Out:
        !   d_slot_index: slot_list(d_slot_index(i)) = d_slot_pop(i), i.e. contains the
        !       original index of entry in slot_list/proc_map.
        !   d_slot_pop: array containing populations of donor slots which we try and redistribute
        !       to receiver processors. This is a reduced version of slot_list
        !       containing only slots corresponding to donor processors.

        integer, intent (in) :: donors(:)
        real(p), intent(in) :: slot_list(0:)
        integer, intent (in) :: proc_map(0:)
        real(p), intent(out) :: d_slot_pop(:)
        integer, intent(out) :: d_slot_index(:)

        integer :: i, j, ndonor

        ndonor = 1

        do i = 1, size(donors)
            do j = 0, size(slot_list) - 1
                ! Putting appropriate blocks of slots in d_slot_pop.
                if (proc_map(j) == donors(i)) then
                    d_slot_pop(ndonor) = slot_list(j)
                    ! Index is important as well.
                    d_slot_index(ndonor) = j
                    ndonor = ndonor + 1
                end if
            end do
        end do

    end subroutine reduce_slots

    subroutine find_processors(procs_pop, up_thresh, low_thresh, proc_map, rec_dummy, don_dummy, donor_slots)

        ! Find donor/receiver processors.
        ! Put these into varying size array receivers/donors.

        ! In:
        !   procs_pop: number particles on each processor.
        !   upper/lower_thresh: upper/lower thresholds for load imblance i.e. how close to the average population
        !       we aspire to.
        !   proc_map: array which maps determinants to processors.
        !       proc_map(modulo(hash(d),load_balancing_slots*nprocs))=processor.
        ! Out:
        !   rec_dummy/don_dummy: arrays which contain donor/receivers processors.
        !   donor_slots: number of slots which we can donate, this varies as more entries in proc_map are
        !       modified.

        use parallel, only: nprocs
        use ranking, only: insertion_rank
        use checking, only: check_allocate, check_deallocate

        real(p), intent(in) :: procs_pop(0:)
        integer, intent(in) :: proc_map(0:)
        real(p), intent(in) :: up_thresh, low_thresh
        integer, intent(out) :: donor_slots
        integer, allocatable, intent(out) :: rec_dummy(:), don_dummy(:)

        integer ::  i, j
        integer :: ierr, nrecv, ndonor
        integer, allocatable ::  tmp_rec(:), tmp_don(:), rec_sort(:)
        integer :: rank_nparticles(nprocs)

        allocate(tmp_rec(0:nprocs-1), stat=ierr)
        call check_allocate('tmp_rec', nprocs, ierr)
        allocate(tmp_don(0:nprocs-1), stat=ierr)
        call check_allocate('tmp_don', nprocs, ierr)

        ndonor = 0
        nrecv = 0

        ! Find donor/receiver processors.

        do i = 0, size(procs_pop) - 1
            if (procs_pop(i) .lt. low_thresh) then
                tmp_rec(nrecv) = i
                nrecv = nrecv + 1
            else if (procs_pop(i) .gt. up_thresh) then
                tmp_don(ndonor) = i
                ndonor = ndonor + 1
            end if
        end do

        ! Put processor ID into smaller array.
        allocate(rec_dummy(nrecv), stat=ierr)
        call check_allocate('rec_dummy', nrecv, ierr)
        allocate(rec_sort(nrecv), stat=ierr)
        call check_allocate('rec_sort', nrecv, ierr)
        allocate(don_dummy(ndonor), stat=ierr)
        call check_allocate('don_dummy', ndonor, ierr)

        don_dummy = tmp_don(:ndonor-1)
        rec_dummy = tmp_rec(:nrecv-1)

        ! Sort receiver processers.
        call insertion_rank(procs_pop, rank_nparticles, 1.0e-8_p)
        do i = 1, size(rec_dummy)
            rec_sort(i) = rank_nparticles(i) - 1
        end do
        rec_dummy = rec_sort

        ! Calculate number of donor slots which we can move.
        donor_slots = 0
        do i = 0, size(proc_map) - 1
            do j = 1, size(don_dummy)
                if (proc_map(i) == don_dummy(j)) then
                    donor_slots = donor_slots + 1
                end if
            end do
        end do

        deallocate(rec_sort, stat=ierr)
        call check_deallocate('rec_sort', ierr)
        deallocate(tmp_rec, stat=ierr)
        call check_deallocate('tmp_rec', ierr)
        deallocate(tmp_don, stat=ierr)
        call check_deallocate('tmp_don', ierr)

    end subroutine find_processors

    subroutine initialise_slot_pop(psip_list, spawn, slot_pop)

        ! In:
        !   psip_list: particle_t object containing the current psip locations and
        !       populations.
        !   spawn: spawn_t object containing 'active' proc_map used to map states to processors.
        ! In/Out:
        !   slot_pop: array containing population of slots in proc_map. Processor dependendent.

        use parallel, only: nprocs
        use qmc_data, only: particle_t
        use spawning, only: assign_particle_processor
        use spawn_data, only: spawn_t

        type(particle_t), intent(in) :: psip_list
        type(spawn_t), intent(in) :: spawn
        real(p), intent(out) :: slot_pop(0:)

        integer :: i, det_pos, iproc_slot

        slot_pop = 0.0_p
        do i = 1, psip_list%nstates
            call assign_particle_processor(psip_list%states(:,i), spawn%bit_str_nbits, spawn%hash_seed, spawn%hash_shift, &
                                           spawn%move_freq, nprocs, iproc_slot, det_pos, spawn%proc_map%map, spawn%proc_map%nslots)
            slot_pop(det_pos) = slot_pop(det_pos) + abs(real(psip_list%pops(1,i),p))
        end do

        ! Remove encoding factor to obtain the true populations.
        slot_pop = slot_pop/psip_list%pop_real_factor

   end subroutine initialise_slot_pop

end module load_balancing
