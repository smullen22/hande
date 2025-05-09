module fci_utils

! Utility/common procedures and data structures for FCI code.

use dmqmc_data, only: subsys_t
use const, only: p
use csr, only: csrp_t

implicit none

! Input options.
type fci_in_t
    ! If true then the non-zero elements of the Hamiltonian matrix are written to hamiltonian_file.
    logical :: write_hamiltonian = .false.
    character(255) :: hamiltonian_file = 'HAMIL'

    ! If true then the determinant list is written to determinant_file.
    logical :: write_determinants = .false.
    character(255) :: determinant_file = 'DETS'

    ! Number of FCI wavefunctions to print out.
    integer :: print_fci_wfn = 0
    ! ...and file to write them to.
    character(255) :: print_fci_wfn_file = 'FCI_WFN'

    ! Number of FCI wavefunctions to compute properties of.
    integer :: analyse_fci_wfn = 0

    ! This stores information for the various RDMs that the user asks to be
    ! calculated. Each element of this array corresponds to one of these RDMs.
    ! NOTE: This can only be equal to 1 currently.
    type(subsys_t), allocatable :: subsys_info(:)

    ! blacs and scalapack split a matrix up into n x n blocks which are then
    ! distributed around the processors in a cyclic fashion.
    ! The block size is critical to performance.  64 seems to be a good value (see
    ! scalapack documentation).
    integer :: block_size = 64

    ! -- Davidson only settings --

    ! True if using Davidson diagonalisation
    logical :: using_davidson = .false.
    ! Number of Davidson eigenpairs to find.
    integer :: ndavidson_eigv = 4
    ! Number of trial vectors
    integer :: ndavidson_trialvec = 8
    ! Size of Davidson basis.
    integer :: davidson_maxsize = 50
    ! Maximum iterations
    integer :: davidson_maxiter = 100
    ! Convergence tolerance
    real(p) :: davidson_tol = 1e-7
    ! A boolean to control whether the diagonal of the FCI Hamiltonian
    ! is generated. This will override the typical FCI where the entire
    ! Hamiltonian is generated and diagonalized.
    logical :: hamiltonian_diagonal_only = .false.
end type fci_in_t


type hamil_t
    ! Matrix to store hamiltonian for systems with purely real hamiltonian elements.
    real(p), allocatable :: rmat(:,:)
    ! Matrix to store hamiltonian for systems with complex hamiltonian elements.
    complex(p), allocatable :: cmat(:,:)
    type(csrp_t) :: smat ! Sparse complex not implemented.
    logical :: comp = .false.
    logical :: sparse = .false.
end type hamil_t

contains

    subroutine init_fci(sys, fci_in, ref, ndets, dets)

        ! Initialisation of FCI calculations.  (Boilerplate, determinant initialisation.)

        ! In:
        !   fci_in: fci input options.
        ! In/Out:
        !   sys: system of interest.
        !   ref: reference determinant.  If a truncated calculation is being performed and
        !        a reference determinant is not supplied, a simple best guess will be created.
        ! Out:
        !   ndets, dets: number of and bit-string representation of determinants in the
        !        selected Hilbert subspace.

        use const, only: i0

        use determinants, only: spin_orb_list, encode_det, write_det
        use determinant_enumeration, only: enumerate_determinants, print_dets_list
        use hamiltonian, only: get_hmatel, get_hmatel_complex
        use reference_determinant, only: reference_t, set_reference_det
        use symmetry, only: symmetry_orb_list

        use errors, only: stop_all
        use utils, only: int_fmt
        use parallel, only: parent

        use system, only: sys_t
        use calc_system_init, only: set_spin_polarisation
        use hamiltonian_data

        type(sys_t), intent(inout) :: sys
        type(fci_in_t), intent(in) :: fci_in
        type(reference_t), intent(inout) :: ref
        integer, intent(out) :: ndets
        integer(i0), allocatable, intent(out) :: dets(:,:)

        integer, allocatable :: sym_space_size(:), occ_list_scratch(:)
        integer :: iunit, ref_ms, ref_sym
        logical :: spin_flip
        integer(i0) :: f0(sys%basis%tot_string_len)
        type(hmatel_t) :: hmatel

        integer :: iunit_out

        iunit_out = 6

        if (parent) then
            write (iunit_out,'(1X,"FCI")')
            write (iunit_out,'(1X,"---",/)')

            if (fci_in%print_fci_wfn /= 0) then
                ! Overwrite any existing file...
                ! Open a fresh file here so we can just append to it later.
                open(newunit=iunit, file=fci_in%print_fci_wfn_file, status='unknown')
                close(iunit, status='delete')
            end if
        end if

        spin_flip = .false.
        if (allocated(ref%occ_list0)) then
            ! detect if doing spin-flip
            ref_ms = spin_orb_list(sys%basis%basis_fns, ref%occ_list0)
            ref_sym = symmetry_orb_list(sys, ref%occ_list0)
            if (sys%Ms == huge(1)) sys%Ms = ref_ms
            if (sys%symmetry == huge(1)) sys%symmetry = ref_sym
            spin_flip = sys%Ms /= ref_ms
        else if (sys%nsym == 1) then
            ! Only one option, so don't force it to be set.
            sys%symmetry = sys%sym0
        else if (sys%Ms == huge(1)) then
            call stop_all('init_fci', 'Spin of Hilbert space not defined.')
        end if

        call set_spin_polarisation(sys%basis%nbasis, sys)

        if (.not.allocated(ref%occ_list0) .and. ref%ex_level /= sys%nel) then
            ! Provide a best guess at the reference determinant given symmetry and spin options.
            call set_reference_det(sys, ref%occ_list0, .true., sys%symmetry, iunit_out)
            if (sys%aufbau_sym) sys%symmetry = symmetry_orb_list(sys, ref%occ_list0)
        else if (sys%aufbau_sym) then
            ! Ensure we set a guess for the symmetry sector if requested.
            call set_reference_det(sys, occ_list_scratch, .false., sys%symmetry, iunit_out)
            sys%symmetry = symmetry_orb_list(sys, occ_list_scratch)
        end if
        if (allocated(ref%occ_list0)) then
            call encode_det(sys%basis, ref%occ_list0, f0)
            if (sys%read_in%comp) then
                hmatel = get_hmatel_complex(sys, f0, f0)
                ref%H00 = real(hmatel%c, p)
            else
                hmatel = get_hmatel(sys, f0, f0)
                ref%H00 = hmatel%r
            end if
        end if

        if (parent) call fci_json(sys, fci_in, ref)

        ! Construct space
        if (allocated(ref%occ_list0)) then
            call enumerate_determinants(sys, .true., spin_flip, ref%ex_level, sym_space_size, ndets, dets, occ_list0=ref%occ_list0)
            call enumerate_determinants(sys, .false., spin_flip, ref%ex_level, sym_space_size, ndets, dets, &
                                        sys%symmetry, ref%occ_list0)
        else
            call enumerate_determinants(sys, .true., spin_flip, ref%ex_level, sym_space_size, ndets, dets)
            call enumerate_determinants(sys, .false., spin_flip, ref%ex_level, sym_space_size, ndets, dets, sys%symmetry)
        end if

        if (fci_in%using_davidson .and. (ndets < fci_in%davidson_maxsize)) then
            write(iunit_out, '(1X,A,I0,A,I0,A)') 'davidson_maxsize ',fci_in%davidson_maxsize, &
            ' is larger than the dimension of the current Hamiltonian spin block, ',ndets,', please decrease it.'
            call stop_all('init_fci','davidson_maxsize exceeds Hamiltonian dimension, please decrease it.')
        end if

        if (fci_in%write_determinants .and. parent) call print_dets_list(sys, ndets, dets, fci_in%determinant_file)

    end subroutine init_fci

    subroutine fci_json(sys, fci_in, ref)

        ! Serialise a FCI input (fci_in_t and reference_t) objects in JSON format.

        ! In:
        !   sys: system of interest.
        !   fci_in: fci_in_t object containing fci input values (including any defaults set).
        !   ref: reference determinant information.

        use json_out
        use reference_determinant, only: reference_t, reference_t_json
        use dmqmc_data, only: subsys_t_json
        use system, only: sys_t, sys_t_json

        type(sys_t), intent(in) :: sys
        type(fci_in_t), intent(in) :: fci_in
        type(reference_t), intent(in) :: ref
        type(json_out_t) :: js

        call json_object_init(js, tag=.true.)
        call sys_t_json(js, sys)
        call json_object_init(js, 'fci_in')

        call json_write_key(js, 'write_hamiltonian', fci_in%write_hamiltonian)
        call json_write_key(js, 'hamiltonian_file', fci_in%hamiltonian_file)
        call json_write_key(js, 'write_determinants', fci_in%write_determinants)
        call json_write_key(js, 'determinant_file', fci_in%determinant_file)
        call json_write_key(js, 'print_fci_wfn', fci_in%print_fci_wfn)
        call json_write_key(js, 'print_fci_wfn_file', fci_in%print_fci_wfn_file)
        call json_write_key(js, 'analyse_fci_wfn', fci_in%analyse_fci_wfn)
        if (allocated(fci_in%subsys_info)) then
            call subsys_t_json(js, fci_in%subsys_info)
        end if
        call json_write_key(js, 'block_size', fci_in%block_size)
        call json_write_key(js, 'ndavidson_eigv', fci_in%ndavidson_eigv)
        call json_write_key(js, 'ndavidson_trialvec', fci_in%ndavidson_trialvec)
        call json_write_key(js, 'davidson_maxsize', fci_in%davidson_maxsize)
        call json_write_key(js, 'davidson_tol', fci_in%davidson_tol)
        call json_write_key(js, 'hamiltonian_diagonal_only', fci_in%hamiltonian_diagonal_only)

        call json_object_end(js)
        call reference_t_json(js, ref, sys, terminal=.true.)
        call json_object_end(js, terminal=.true., tag=.true.)
        write (js%io,'()')

    end subroutine fci_json

    subroutine generate_hamil(sys, ndets, dets, hamil, proc_blacs_info, full_mat, use_sparse_hamil, diagonal_only)

        ! Generate a symmetry block of the Hamiltonian matrix, H = < D_i | H | D_j >.
        ! The list of determinants, {D_i}, is grouped by symmetry and contains
        ! only determinants of a specified spin.
        ! Only generate the upper diagonal for use with (sca)lapack routine.
        ! In:
        !    sys: system to be studied.
        !    ndets: number of determinants in the Hilbert space.
        !    dets: list of determinants in the Hilbert space (bit-string representation).
        !    proc_blacs_info (optional): BLACS distribution (and related info) of the Hamiltonian matrix.
        !    full_mat (optional): if present and true generate the full matrix rather than
        !        just storing one triangle.
        !    use_sparse_hamil (optional): if present and true generate a sparse matrix format, as
        !        described in csr.
        !    diagonal_only (optional): if present and true, generate only the
        !        diagonal elements < D_i | H | D_i >
        ! Out:
        !    hamil: hamil_t derived type, containing Hamiltonian matrix in a square array of appropriate
        !        format for system and settings given (real, complex or sparse). In a complex system only
        !        sparse format is not implemented.

        use checking, only: check_allocate, check_deallocate
        use csr, only: init_csrp, end_csrp, csrp_t
        use errors, only: stop_all
        use parallel

        use hamiltonian, only: get_hmatel, get_hmatel_complex

        use real_lattice
        use system, only: sys_t
        use hamiltonian_data

        type(sys_t), intent(in) :: sys
        integer, intent(in) :: ndets
        integer(i0), intent(in) :: dets(:,:)
        type(hamil_t), intent(out) :: hamil
        type(blacs_info), intent(in), optional :: proc_blacs_info
        logical, intent(in), optional :: full_mat, use_sparse_hamil, diagonal_only
        integer :: ierr
        integer :: i, j, ii, jj, ilocal, iglobal, jlocal, jglobal, nnz, imode
        logical :: sparse_mode
        type(hmatel_t) :: hmatel
        integer :: iunit

        iunit = 6

        hamil%comp = sys%read_in%comp
        if (present(use_sparse_hamil)) then
             hamil%sparse = use_sparse_hamil
        end if
        sparse_mode = hamil%sparse
        if (sparse_mode .and. present(proc_blacs_info)) then
            call stop_all('generate_hamil', &
                'Sparse distributed matrices are not currently implemented.  &
                &If this is disagreeable to you, please contribute patches resolving this situation.')
        end if
        if (hamil%comp .and. hamil%sparse) then
            call stop_all('generate_hamil', &
                'Complex sparse matrices are not currently implemented.  &
                &If this is disagreeable to you, please contribute patches resolving this situation.')
        end if

        if (.not.hamil%sparse .and. .not.present(diagonal_only)) then
            ilocal = ndets
            jlocal = ndets
            if (present(proc_blacs_info)) then
                ilocal = proc_blacs_info%nrows
                jlocal = proc_blacs_info%ncols
            end if
            if (hamil%comp) then
                allocate(hamil%cmat(ilocal, jlocal), stat=ierr)
                call check_allocate('hamil_comp%cmat', ilocal*jlocal, ierr)
            else
                allocate(hamil%rmat(ilocal, jlocal), stat=ierr)
                call check_allocate('hamil_comp%rmat', ilocal*jlocal, ierr)
            end if
        else if (.not.hamil%sparse .and. present(diagonal_only)) then
            if (hamil%comp) then
                allocate(hamil%cmat(ndets,1), stat=ierr)
                call check_allocate('hamil_comp%cmat', ndets*1, ierr)
            else
                allocate(hamil%rmat(ndets,1), stat=ierr)
                call check_allocate('hamil_comp%rmat', ndets*1, ierr)
            end if
        end if

        ! Form the Hamiltonian matrix < D_i | H | D_j >.
        if (present(proc_blacs_info)) then
            ! blacs divides the matrix up into sub-matrices of size block_size x block_size.
            ! The blocks are distributed in a cyclic fashion amongst the
            ! processors.
            ! Each processor stores a total of nrows of the matrix.
            ! i gives the index of the first row in the current block.
            ! ii gives the index of the current row within the current block.
            ! The local i index is thus i-1+ii.  This is used to refer to the
            ! matrix element as stored (continuously) on the processor.
            ! The global i index is given by the sum of the rows held on
            ! preceeding proecssors for the previous loops over processors (as
            ! done in the loop over i), the rows held on other processors during
            ! the corrent loop over processors and the position within the
            ! current block.
            ! Similarly for the other indices.
            do i = 1, proc_blacs_info%nrows, proc_blacs_info%block_size
                do ii = 1, min(proc_blacs_info%block_size, proc_blacs_info%nrows - i + 1)
                    ilocal = i - 1 + ii
                    iglobal = (i-1)*proc_blacs_info%nproc_rows + proc_blacs_info%procx*proc_blacs_info%block_size + ii
                    do j = 1, proc_blacs_info%ncols, proc_blacs_info%block_size
                        do jj = 1, min(proc_blacs_info%block_size, proc_blacs_info%ncols - j + 1)
                            jlocal = j - 1 + jj
                            jglobal = (j-1)*proc_blacs_info%nproc_cols + proc_blacs_info%procy*proc_blacs_info%block_size + jj
                            if (hamil%comp) then
                                hmatel = get_hmatel_complex(sys, dets(:,iglobal), dets(:,jglobal))
                                hamil%cmat(ilocal, jlocal) = hmatel%c

                            else
                                hmatel = get_hmatel(sys, dets(:,iglobal), dets(:,jglobal))
                                hamil%rmat(ilocal, jlocal) = hmatel%r

                            end if
                        end do
                    end do
                end do
            end do
        else if (sparse_mode) then
                ! First, find out how many non-zero elements there are.
                ! We'll be naive and not just test for non-zero by symmetry, but
                ! actually calculate all matrix elements for now.
                ! Then, store the Hamiltonian.
                do imode = 1, 2
                    nnz = 0
                    !$omp parallel
                    do i = 1, ndets
                        ii = i
                        if (present(full_mat)) then
                            if (full_mat) ii = 1
                        end if
                        ! OpenMP chunk size determined completely empirically
                        ! from a single test.  Please feel free to improve...
                        !$omp do private(j, hmatel) schedule(dynamic, 200)
                        do j = ii, ndets
                            hmatel = get_hmatel(sys, dets(:,i), dets(:,j))
                            if (abs(hmatel%r) > depsilon) then
                                !$omp critical
                                nnz = nnz + 1
                                if (imode == 2) then
                                    hamil%smat%mat(nnz) = hmatel%r
                                    hamil%smat%col_ind(nnz) = j
                                    if (hamil%smat%row_ptr(i) == 0) hamil%smat%row_ptr(i) = nnz
                                end if
                                !$omp end critical
                            end if
                        end do
                        !$omp end do
                    end do
                    !$omp end parallel
                    if (imode == 1) then
                        write (iunit,'(1X,a50,i8,/)') 'Number of non-zero elements in Hamiltonian matrix:', nnz
                        call init_csrp(hamil%smat, ndets, nnz, .true.)
                        hamil%smat%row_ptr(1:ndets) = 0
                    else
                        ! Any element not set in row_ptr means that the
                        ! corresponding row has no non-zero elements.
                        ! Set it to be identical to the next row (this avoids
                        ! looping over the zero-row).
                        do i = ndets, 1, -1
                            if (hamil%smat%row_ptr(i) == 0) hamil%smat%row_ptr(i) = hamil%smat%row_ptr(i+1)
                        end do
                    end if
                end do
        else if (present(diagonal_only)) then
            do i = 1, ndets
                if (hamil%comp) then
                    hmatel = get_hmatel_complex(sys,dets(:,i),dets(:,i))
                    hamil%cmat(i,1) = hmatel%c

                else
                    hmatel = get_hmatel(sys,dets(:,i),dets(:,i))
                    hamil%rmat(i,1) = hmatel%r

                end if
            end do
        else
            !$omp parallel
            do i = 1, ndets
                ii = i
                if (present(full_mat)) then
                    if (full_mat) ii = 1
                end if
                !$omp do private(j) schedule(dynamic, 200)
                do j = ii, ndets
                    if (hamil%comp) then
                        hmatel = get_hmatel_complex(sys,dets(:,i),dets(:,j))
                        hamil%cmat(i,j) = hmatel%c

                    else
                        hmatel = get_hmatel(sys,dets(:,i),dets(:,j))
                        hamil%rmat(i,j) = hmatel%r

                    end if
                end do
                !$omp end do
            end do
            !$omp end parallel
        end if

    end subroutine generate_hamil

    subroutine write_hamil(hamiltonian_file, ndets, proc_blacs_info, hamil)

        ! Write out the Hamiltonian matrix to file.

        ! In:
        !    hamiltonian_file: filename.  Overwritten if exists.
        !    ndets: number of determinants in Hilbert space.
        !    proc_blacs_info (optional, required if nprocs>1): BLACS distribution
        !        (and related info) of the Hamiltonian matrix.
        !    hamil: hamil_t derived type containing hamiltonian matrix in appropriate
        !        matrix format (real, complex or sparse matrix).

        use checking, only: check_allocate, check_deallocate
        use const, only: p, depsilon
        use errors, only: stop_all
        use linalg, only: plaprnt
        use parallel, only: blacs_info, nprocs

        use csr, only: csrp_t

        character(*), intent(in) :: hamiltonian_file
        integer, intent(in) :: ndets
        type(blacs_info), intent(in), optional :: proc_blacs_info
        type(hamil_t), intent(in) :: hamil

        integer :: iunit, i, j, ierr
        real(p), allocatable :: work_print(:)
        complex(p), allocatable :: cwork_print(:)

        open(newunit=iunit, file=hamiltonian_file, status='unknown')
        if (nprocs > 1 .and. (.not.hamil%comp)) then
            if (.not.present(proc_blacs_info)) call stop_all('write_hamil', 'proc_blacs_info not supplied.')
            ! Note that this uses a different format to the serial case...
            if (hamil%comp) then
                allocate(cwork_print(proc_blacs_info%block_size**2), stat=ierr)
                call check_allocate('cwork_print', proc_blacs_info%block_size**2, ierr)
                call plaprnt(ndets, ndets, hamil%cmat, 1, 1, proc_blacs_info%desc_m, 0, 0, 'hamil%rmat', iunit, cwork_print)
                deallocate(cwork_print)
                call check_deallocate('cwork_print', ierr)
            else
                allocate(work_print(proc_blacs_info%block_size**2), stat=ierr)
                call check_allocate('work_print', proc_blacs_info%block_size**2, ierr)
                call plaprnt(ndets, ndets, hamil%rmat, 1, 1, proc_blacs_info%desc_m, 0, 0, 'hamil%cmat', iunit, work_print)
                deallocate(work_print)
                call check_deallocate('work_print', ierr)
            end if
        else
            if (hamil%sparse) then
                j = 1
                do i = 1, size(hamil%smat%mat)
                    if (abs(hamil%smat%mat(i)) > depsilon) then
                        if (hamil%smat%row_ptr(j+1) <= i) j = j+1
                        write (iunit,*) j, hamil%smat%col_ind(i), hamil%smat%mat(i)
                    end if
                end do
            else
                do i=1, ndets
                    call write_hamil_entry(hamil, i, i, iunit)
                    do j=i+1, ndets
                        call write_hamil_entry(hamil, i, j, iunit)
                    end do
                end do
            end if
        end if
        close(iunit, status='keep')

        contains

            subroutine write_hamil_entry(hamil, i, j, iunit)

                type(hamil_t), intent(in) :: hamil
                integer, intent(in) :: i, j, iunit

                if (hamil%comp) then
                    if (i==j .or. abs(hamil%cmat(i,j)) > depsilon) write (iunit,*) i, j, hamil%cmat(i,j)
                else
                    if (i==j .or. abs(hamil%rmat(i,j)) > depsilon) write (iunit,*) i, j, hamil%rmat(i,j)
                end if

            end subroutine write_hamil_entry

    end subroutine write_hamil

end module fci_utils
