program analyse_rdm

    use dSFMT_interface
    use const

    implicit none

    integer :: rdm_unit, stat, lwork, ierr, info
    real(dp), allocatable :: work(:)
    real(dp) :: rand_var
    integer :: rdm_size
    integer :: i, j, k
    logical :: does_exist

    type(dSFMT_t) :: rng
    integer :: seed, nRDM, nargs
    character(256) :: filename, arg

    real(dp) :: next_gaussian_rv
    logical :: gaussian_rv_left

    real(dp), allocatable :: rdm_elements(:,:), rdm_with_noise(:,:), rdm_errors(:,:)
    real(dp), allocatable :: eigv(:)
    real(dp) :: temp_store(2)
    real(dp) :: vn_entropy, renyi_2

    seed = 328576
    nRDM = 10000
    nargs = command_argument_count()

    if (nargs == 0 .or. nargs > 3) then
        call get_command_argument(0,arg)
        write (6,*) trim(arg)//' calculate entropy estimates from an averaged RDM and produce a'
        write (6,*) 'set of RDMs with random (Gaussian noise added).'
        write (6,*)
        write (6,*) 'Usage:'
        write (6,*)
        write (6,*) trim(arg)//' AVERAGE_RDM [SEED [nRDM]]'
        write (6,*) 
        write (6,*) 'where AVERAGE_RDM is produced by average_rdm.py,'
        write (6,*) 'SEED (optional, default 328576), is the random number seed'
        write (6,*) 'and nRDM (optional, default 10000) is the number of noisy RDMs to produce.'
        write (6,*) '(Noisy RDMs are produced by adding Gaussian noise to each element'
        write (6,*) 'according to the standard error in the estimate of that element.'
        stop 999
    end if

    call get_command_argument(1,filename)
    if (nargs > 1) then
        call get_command_argument(2,arg)
        read(arg,*) seed
    end if
    if (nargs > 2) then
        call get_command_argument(3,arg)
        read(arg,*) nRDM
    end if

    inquire(file=filename, exist=does_exist)

    if (.not. does_exist) then
        write(6,'(a21)') "RDM file "//trim(filename)//" does not exist."
        stop 999
    end if

    call dSFMT_init(seed, nRDM*2, rng)

    rdm_unit = 10
    open(rdm_unit, file=filename, status='old')
    read(rdm_unit, *, iostat=stat) rdm_size

    allocate(rdm_elements(rdm_size, rdm_size))
    allocate(rdm_with_noise(rdm_size, rdm_size))
    allocate(rdm_errors(rdm_size, rdm_size))
    allocate(eigv(rdm_size))
    rdm_elements = 0.0_dp
    rdm_errors = 0.0_dp
    eigv = 0.0_dp

    ! Read in the RDM elements and errors to the above arrays.
    do i = 1, rdm_size
        do j = i, rdm_size
            read(rdm_unit, *, iostat=stat) temp_store
            rdm_elements(i,j) = temp_store(1)
            rdm_elements(j,i) = temp_store(1)
            rdm_errors(i,j) = temp_store(2)
        end do
    end do

    ! Temporary space, as dsyev will destory the upper half of the input matrix.
    rdm_with_noise = rdm_elements

    ! Find the optimal size of the workspace.
    allocate(work(1), stat=ierr)
    call dsyev('N', 'U', rdm_size, rdm_with_noise, rdm_size, eigv, work, -1, info)
    lwork = nint(work(1))
    deallocate(work)
    allocate(work(lwork), stat=ierr)

    ! Now perform the diagonalisation.
    call dsyev('N', 'U', rdm_size, rdm_with_noise, rdm_size, eigv, work, lwork, info)

    ! Find the mean estimate.
    vn_entropy = calculate_von_neumann_entropy(eigv)
    write(6,'(a35,f12.7)') "# von Neumann entropy mean estimate =", vn_entropy

    ! Now, estimate the error on the estimate of the above VN entropy by adding Gaussian noise
    ! to the mean RDM elements.
    do k = 1, nRDM

        ! Loop over all elements and add the appropriate noise.
        do i = 1, rdm_size
            do j = i, rdm_size
                rand_var = rdm_errors(i,j)*get_rand_gaussian(rng)
                rdm_with_noise(i,j) = rdm_elements(i,j) + rand_var
                rdm_with_noise(j,i) = rdm_with_noise(i,j)
            end do
        end do

        call dsyev('N', 'U', rdm_size, rdm_with_noise, rdm_size, eigv, work, lwork, info)

        ! Calculate and write out the estmate from the noisy RDM.
        vn_entropy = calculate_von_neumann_entropy(eigv)
        write(6,'(f12.7)') vn_entropy

    end do

    ! Next calculate Renyi 2 entropy.

    ! First, the mean estimate from the RDM without noise added.
    rdm_with_noise = rdm_elements
    call dsyev('N', 'U', rdm_size, rdm_with_noise, rdm_size, eigv, work, lwork, info)

    renyi_2 = calculate_renyi_2_entropy(eigv)
    write(6,'(a33,f12.7)') "# Renyi 2 entropy mean estimate =", renyi_2

    ! Then, once again, add noise to estimate the error.
    do k = 1, nRDM

        do i = 1, rdm_size
            do j = i, rdm_size
                rand_var = rdm_errors(i,j)*get_rand_gaussian(rng)
                rdm_with_noise(i,j) = rdm_elements(i,j) + rand_var
                rdm_with_noise(j,i) = rdm_with_noise(i,j)
            end do
        end do

        call dsyev('N', 'U', rdm_size, rdm_with_noise, rdm_size, eigv, work, lwork, info)

        renyi_2 = calculate_renyi_2_entropy(eigv)
        write(6,'(f12.7)') renyi_2

    end do

    call dSFMT_end(rng)

contains

        function calculate_r2_error(rdm_size, rdm, rdm_error) result(error)

            ! This function calculate the error on Renyi 2 directly using the error
            ! propagation formula, rather than by adding noise. This is for checking.

            integer, intent(in) :: rdm_size
            real(dp), intent(in) :: rdm(rdm_size, rdm_size), rdm_error(rdm_size, rdm_size)
            real(dp) :: error, elem_sum, derivative
            integer :: i, j

            elem_sum = 0.0_dp
            do i = 1, rdm_size
                do j = 1, rdm_size
                    elem_sum = elem_sum + rdm(i,j)**2
                end do
            end do
            elem_sum = 2.0_dp/elem_sum

            error = 0.0_dp
            do i = 1, rdm_size
                do j = 1, rdm_size
                    derivative = elem_sum*rdm(i,j)
                    derivative = derivative/log(2.0_dp)
                    error = error + (derivative**2)*(rdm_error(i,j)**2)
                end do
            end do
            error = sqrt(error)

        end function calculate_r2_error

        function calculate_r2_direct(rdm_size, rdm) result(renyi_2)

            ! Function to calculate Renyi 2 from matrix elements rather than from
            ! the eigenvalues. This is for checking.

            integer, intent(in) :: rdm_size
            real(dp), intent(in) :: rdm(rdm_size, rdm_size)
            real(dp) :: renyi_2, elem_sum
            integer :: i, j

            renyi_2 = 0.0_dp
            do i = 1, rdm_size
                do j = 1, rdm_size
                    renyi_2 = renyi_2 + rdm(i,j)**2
                end do
            end do

            renyi_2 = -log(renyi_2)/log(2.0_dp)

        end function calculate_r2_direct

        function calculate_von_neumann_entropy(eigv) result(vn_entropy)

            ! Calculate VN entropy from a set of eigenvalues.

            real(dp), intent(out) :: eigv(:)
            real(dp) :: vn_entropy
            integer :: i

            vn_entropy = 0.0_dp
            do i = 1, ubound(eigv,1)
                ! Throw away all eigenvalues which are zero or negative.
                if (.not. (eigv(i) > 0.0_dp)) then
                    cycle
                end if
                vn_entropy = vn_entropy - eigv(i)*(log(eigv(i))/log(2.0_p))
            end do

        end function calculate_von_neumann_entropy

        function calculate_renyi_2_entropy(eigv) result(renyi_2)

            ! Calculate Renyi entropy from a set of eigenvalues.

            real(dp), intent(out) :: eigv(:)
            real(dp) :: renyi_2
            integer :: i

            renyi_2 = 0.0_dp
            do i = 1, ubound(eigv,1)
                renyi_2 = renyi_2 + eigv(i)**2
            end do
            renyi_2 = -log(renyi_2)/log(2.0_dp)

        end function calculate_renyi_2_entropy

end program analyse_rdm
