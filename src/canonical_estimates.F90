module canonical_estimates

! Estimate the various energy estimates in the canonical ensemble.
! Let H = T + V, then we can estimate thermodynamic values for <H>,
! where <X> = Tr(X\rho)/Tr(\rho), for the density matrix \rho using
! various level of approximations.
! Here we calculate <H> using two different density matrices, namely:
! 1) \rho_0 = \sum_I e^{-\beta \sum_{i}^{M} \varepsilon_i n_i} |D_I><D_I|,
! for many particle states |D_I>, and varepsilon_i is the single-particle orbital
! energy.
! 2) \rho_HF = \sum_I e^{-\beta E^HF_I} |D_I><D_I|, where E^HF_I = <D_I|H|D_I>.
! With these definitions we can the calculate the kinetic energy (T) and potential
! energies V) using a Monte Carlo sampling scheme.
! Note that for molecular systems we don't actually evaluate the kinetic energy
! directly but rather the sum of Hartree-Fock eigenvalues. The double counting
! correction is then added from the potential contribution.
! The following enumerators set the location in the estimates array.

use const

implicit none

enum, bind(c)
    ! Ensure energy estimates are always first.
    ! <T>_0.
    enumerator :: ke_idx = 1
    ! <V>_0.
    enumerator :: pe_idx
    ! <T>_HF.
    enumerator :: hf_ke_idx
    ! <V>_HF.
    enumerator :: hf_pe_idx
    ! Finite-T reweighted estimate for partition function = Tr(\rho_HF).
    enumerator :: hf_part_idx
    ! Number of generated N particle states.
    enumerator :: naccept_idx
    ! Index for checking for interaction with the calculation.
    enumerator :: comms_found_idx
    ! last_idx-1 gives number of estimates.
    enumerator :: last_idx
end enum


contains

    subroutine estimate_canonical(sys, fermi_temperature, beta, nattempts, ncycles, all_spin_sectors, rng_seed)

        ! From the Fermi factors calculated in the grand canonical ensemble we can
        ! estimate various mean field properties of canonical ensemble by generating determinants
        ! with arbitrary particle number and only keeping those with <N> = nel.

        ! In:
        !    beta: target temperature.
        !    fermi_temperature: if true, rescale beta as the inverse reduced temperature:
        !        beta = 1/\Theta = T_F/T.  If false, then beta is in atomic units.
        !    nattempts: number of attempts to generate N particle state each cycle.
        !    ncycles: number of Monte Carlo cycles to perform, over which the kinetic energy is
        !        estimated, along with an estimate of the standard error.
        !    rng_seed : seed to initialise the random number generator.
        !    all_spin_sectors: if true then average over ms otherwise only
        !       provide estimates for specified spin sector.
        ! In/Out:
        !    sys: system being studied.

        use system
        use dSFMT_interface, only: dSFMT_t, dSFMT_init, dSFMT_end
        use json_out
        use parallel

        use hamiltonian_ueg, only: exchange_energy_ueg
        use hamiltonian_molecular, only: double_counting_correction_mol
        use determinants, only: sum_sp_eigenvalues_occ_list
        use interact, only: calc_interact, check_comms_file
        use proc_pointers, only: energy_diff_ptr
        use errors, only: stop_all
        use reference_determinant, only: set_reference_det
        use chem_pot, only: find_chem_pot

        use calc_system_init, only: set_spin_polarisation

        type(sys_t), intent(inout) :: sys
        logical, intent(in) :: all_spin_sectors
        real(p), intent(in) :: beta
        logical, intent(in) :: fermi_temperature
        integer, intent(in) :: nattempts
        integer, intent(in) :: ncycles
        integer, intent(in) :: rng_seed

        real(dp) :: p_single(sys%basis%nbasis)
        integer :: occ_list(sys%nel), iorb, ireport
        real(p) :: energy(hf_part_idx), beta_loc, mu(1:2)
        integer(int_64) :: iattempt
        real(p) :: local_estimators(last_idx-1), estimators(last_idx-1)

        type(sys_t) :: sys_bak
        type (dSFMT_t) :: rng
        logical :: soft_exit, comms_found
        integer :: ngen, nalpha_allowed, nbeta_allowed
        real(p) :: ref_shift, correction, mu_tmp
        integer, allocatable :: occ_list0(:)
        type(json_out_t) :: js
#ifdef PARALLEL
        integer :: ierr
#endif
        integer :: iunit

        iunit = 6

        if (parent) write (iunit,'(1X,a16,/,1X,16("-"),/)') 'Canonical energy'

        call dSFMT_init(rng_seed+iproc, 50000, rng)
        call copy_sys_spin_info(sys, sys_bak)
        call set_spin_polarisation(sys%basis%nbasis, sys)

        ! Check that fermi_temperature is only used in cases which it is correct.
        if (sys%system == ueg .and. fermi_temperature .and. sys%Ms /= 0 .and. sys%Ms /= sys%nel) then
            call stop_all('check_canonical_opts', 'The fermi energy, and therefore fermi_temperature &
                               &is incorrect for the spin polarization. Please implement.')
        end if

        beta_loc = beta
        if (fermi_temperature) then
            beta_loc = beta_loc / sys%ueg%ef
        end if
        mu = find_chem_pot(sys, beta_loc)
        correction = free_energy_correction(sys, mu, beta_loc)

        if (parent) then
            call json_object_init(js, tag=.true.)
            call sys_t_json(js, sys)
            call json_write_key(js, 'all_spin_sectors', all_spin_sectors)
            call json_write_key(js, 'beta', beta)
            call json_write_key(js, 'fermi_temperature', fermi_temperature)
            call json_write_key(js, 'nattempts', nattempts)
            call json_write_key(js, 'free_energy_corr', correction)
            call json_write_key(js, 'ncycles', ncycles)
            call json_write_key(js, 'chem_pot', mu)
            call json_write_key(js, 'rng_seed', rng_seed, terminal=.true.)
            call json_object_end(js, terminal=.true., tag=.true.)
            write (js%io,'()')
        end if

        call set_reference_det(sys, occ_list0, .false., sys%symmetry, iunit)

        select case(sys%system)
        case (ueg)
            energy_diff_ptr => exchange_energy_ueg
        case (read_in)
            energy_diff_ptr => double_counting_correction_mol
        case default
            call stop_all('estimate_estimates', 'Not implemented for selected model Hamiltonian')
        end select
        ! Add a shift to the exponentials of the Boltzman factors to prevent
        ! numerical problems at lower temperatures.
        ref_shift = energy_diff_ptr(sys, occ_list0)

        if (parent) then
            write (iunit,'(1X,a87)') '<T>_0: Estimate for kinetic energy in non-interacting ensemble i.e. 1/Z_0 Tr(\rho_0 T).'
            write (iunit,'(1X,a96)') '<V>_0: Estimate for potential energy in non-interacting ensemble energy&
                                    & i.e. 1/Z_0 Tr(\rho_0 V).'
            write (iunit,'(1X,a70)') 'Tr(T\rho_HF): Estimate for numerator of "Hartree-Fock" kinetic energy.'
            write (iunit,'(1X,a72)') 'Tr(V\rho_HF): Estimate for numerator of "Hartree-Fock" potential energy.'
            write (iunit,'(1X,a72)') 'Tr(\rho_HF): Estimate for denominator of "Hatree-Fock" energy i.e. Z_HF.'
            write (iunit,'(1X,a114)') 'N_ACC/N_ATT: Ratio of number of generated N particle states to number &
                                   &of attempts. Also Estimate for Z_GC(N)/Z_GC.'
            write (iunit,'()')
        end if

        if (parent) write (iunit,'(1X,a12,17X,a5,17X,a5,14x,a12,10X,a12,11X,a11,10X,a12)') &
                    '# iterations', '<T>_0', '<V>_0', 'Tr(T\rho_HF)', 'Tr(V\rho_HF)', 'Tr(\rho_HF)', 'N_ACC/N_ATT'

        ! Calculate orbital occupancies.
        p_single = 0.0_p
        do iorb=1, sys%basis%nbasis
            mu_tmp = mu(2 - mod(iorb,2))
            p_single(iorb) = 1.0_p/(1+exp(beta_loc*(sys%basis%basis_fns(iorb)%sp_eigv-mu_tmp)))
        end do

        if (all_spin_sectors) then
            ! If averaging over spin we need to allow for the number of
            ! alpha/beta orbitals to fluctuate between [0,sys%nel].
            nalpha_allowed = sys%nel
            nbeta_allowed = sys%nel
        else
            nalpha_allowed = sys%nalpha
            nbeta_allowed = sys%nbeta
        end if

        do ireport = 1, ncycles
            local_estimators = 0.0_p
            do iattempt = 1, nattempts
                ngen = 0
                occ_list = 0
                if (nalpha_allowed > 0) call generate_allowed_orbital_list(sys, rng, p_single, nalpha_allowed, &
                                                                           1, occ_list, ngen)
                if (.not. all_spin_sectors .and. ngen /= sys%nalpha) then
                    cycle
                else if (ngen > nalpha_allowed) then
                    cycle
                end if
                if (nbeta_allowed > 0) call generate_allowed_orbital_list(sys, rng, p_single, sys%nel-ngen, &
                                                                          2, occ_list, ngen)
                if (ngen /= sys%nel) cycle
                local_estimators(naccept_idx) = local_estimators(naccept_idx) + 1
                ! Calculate Kinetic and Hartree-Fock exchange energies.
                energy(ke_idx) = sum_sp_eigenvalues_occ_list(sys, occ_list)
                ! Add in the core contribution here for molecular systems.
                energy(pe_idx) = energy_diff_ptr(sys, occ_list)
                ! We generate determinants with probability p(i1,..,iN) =
                ! 1/Z_0 \prod_{i} p(i1)X...Xp(iN), where Z_0 is the
                ! non-interacting canonical partition function, and p(i1) =
                ! e^{-\beta \varepsilon_i1}. We can instead
                ! calculate Z_HF = \sum_{i} e^{-\beta E_HF(i)} by reweighting,
                ! i.e.,
                ! p(i1,..,iN)_HF = 1/Z' e^{-beta(E_HF(i)-E_0(i))}p(i1,...,iN),
                ! where Z' = \sum_{i} e^{-\beta(E_HF(i)-E_0(i))}.
                energy(hf_part_idx) = exp(-beta_loc*(energy(pe_idx)-ref_shift))
                energy(hf_ke_idx:hf_pe_idx) = energy(hf_part_idx)*energy(ke_idx:pe_idx)
                local_estimators(ke_idx:hf_part_idx) = local_estimators(ke_idx:hf_part_idx) + energy
            end do

            if (check_comms_file()) local_estimators(comms_found_idx) = 1.0_p

#ifdef PARALLEL
            ! More efficient in parallel.
            call mpi_allreduce(local_estimators, estimators, last_idx-1, mpi_preal, MPI_SUM, MPI_COMM_WORLD, ierr)
#else
            estimators = local_estimators
#endif
            ! Average over processors.
            estimators(ke_idx:hf_part_idx) = estimators(ke_idx:hf_part_idx) / estimators(naccept_idx)
            if (abs(estimators(naccept_idx)) < depsilon) call stop_all('estimate_estimates', 'Number of generated configurations &
                                                                       &is zero, increase number of attempts in input file.')
            if (parent) write(iunit,'(3X,i10,5X,2(es17.10,5X),4X,4(es17.10,5X))') ireport, estimators(ke_idx), &
                                                             estimators(pe_idx), estimators(hf_ke_idx), &
                                                             estimators(hf_pe_idx), estimators(hf_part_idx), &
                                                             real(estimators(naccept_idx),p)/(nattempts*nprocs)
            comms_found = abs(estimators(comms_found_idx)) > depsilon
            call calc_interact(comms_found, iunit, soft_exit)
            if (soft_exit) exit
        end do

        if (parent) write(iunit, '()')

        ! Return sys in unaltered state.
        call copy_sys_spin_info(sys_bak, sys)

        call dSFMT_end(rng)

    end subroutine estimate_canonical

    subroutine generate_allowed_orbital_list(sys, rng, porb, nselect, ispin, occ_list, ngen)

        ! Generate a list of orbitals according to their single
        ! particle GC orbital occupancy probabilities.

        ! In:
        !    sys: system being studied.
        !    porb: porb(i) gives the probabilty of selecting
        !        the orbital i.
        !    nselect: number of orbitals to select.
        !    ispin: integer to account for odd/even ordering of alpha/beta
        !       spin orbitals. Set to 1 for alpha spins, 2 for beta spins.
        ! In/Out:
        !    rng: random number generator.
        !    ngen: running total number of electrons calculated. Should be zerod
        !       upon first call to generate_allowed_orbital_list.
        ! Out:
        !    occ_list: array containing occupied orbitals.

        use dSFMT_interface, only: dSFMT_t, get_rand_close_open
        use system, only: sys_t

        type(sys_t), intent(in) :: sys
        real(dp), intent(in) :: porb(:)
        integer, intent(in) :: nselect
        integer, intent(in) :: ispin
        type(dSFMT_t), intent(inout) :: rng
        integer, intent(out) :: occ_list(:)
        integer, intent(inout) :: ngen

        integer :: iorb, iselect
        real(dp) :: r

        iselect = 0

        do iorb = ispin, sys%basis%nbasis, 2
            ! Select a random orbital.
            r = get_rand_close_open(rng)
            if (porb(iorb) > r) then
                iselect = iselect + 1
                ngen = ngen + 1
                if (iselect > nselect) then
                    ! Selected too many.
                    exit
                end if
                occ_list(ngen) = iorb
            end if
        end do

    end subroutine generate_allowed_orbital_list

    pure function free_energy_correction(sys, mu, beta) result(correction)

        ! Given an estimate for Z_GC(N)/Z_GC = N_ACC/N_ATT evaluated above, we can
        ! estimate the non-interacting free energy as:
        ! F^0_C = -kT log(e^{-beta mu N}Z_GC(N)), so given N_ACC/N_ATT = d, it follows that
        ! F^0_C = -kT log(d) -kT log(Z_GC) + mu N = -kT log(d) + Omega + mu N, where Omega is
        ! is the grand potential. This routine evaluates Omega and mu N, which can then be
        ! combined with the estimate for -kT log(d) during post processing.

        ! In:
        !    sys: system begin studied.
        !    mu: chemical potential.
        !    beta: inverse temperature.

        use system, only: sys_t

        type(sys_t), intent(in) :: sys
        real(p), intent(in) :: mu(1:2), beta

        real(p) :: omega, correction
        integer :: ispin, iorb, nels(1:2)

        omega = 0.0_p
        correction = 0.0_p
        nels = (/ sys%nalpha, sys%nbeta /)

        do ispin = 1, 2
            if (nels(ispin) > 0) then
                do iorb = ispin, sys%basis%nbasis, 2
                    omega = omega + log(1.0_p+exp(-beta*(sys%basis%basis_fns(iorb)%sp_eigv-mu(ispin))))
                end do
                correction = correction + mu(ispin)*nels(ispin)
            end if
        end do

        correction = correction + (-1.0_p/beta)*omega

    end function free_energy_correction

end module canonical_estimates
