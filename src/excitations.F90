module excitations

! Module for dealing with excitations.

use const

implicit none

! A handy type for containing the excitation information needed to connect one
! determinant to another.
type excit_t
    ! Excitation level.
    integer :: nexcit
    ! Orbitals which are excited from and to.
    ! Only used for single and double excitations; undefined otherwise.
    integer :: from_orb(2), to_orb(2)
    ! True if a total odd number of permutations is required to align
    ! the determinants.  Only used for single and double excitations.
    ! Undefined otherwise.
    logical :: perm
end type excit_t

contains

    subroutine init_excitations(basis)

        ! Allocate and initialise data in excit_mask.

        ! In/Out:
        !    basis: information about the single-particle basis.  On output the
        !       excit_mask component is also set.

        use basis_types, only: basis_t
        use checking, only: check_allocate

        type(basis_t), intent(inout) :: basis
        integer :: ibasis, jbasis, ipos, iel, jpos, jel, ierr

        allocate(basis%excit_mask(basis%tot_string_len, basis%nbasis), stat=ierr)
        call check_allocate('basis%excit_mask', basis%bit_string_len*basis%nbasis, ierr)

        basis%excit_mask = 0_i0

        do ibasis = 1, basis%nbasis
            ipos = basis%bit_lookup(1, ibasis)
            iel = basis%bit_lookup(2, ibasis)
            ! Set bits corresponding to all orbitals above ibasis.
            ! Sure, there are quicker (and probably more elegant) ways of doing
            ! this, but it's a one-off...
            do jbasis = 1, basis%nbasis
                jpos = basis%bit_lookup(1, jbasis)
                jel = basis%bit_lookup(2, jbasis)
                if ( (jel==iel .and. jpos > ipos) .or. jel>iel) &
                    basis%excit_mask(jel, ibasis) = ibset(basis%excit_mask(jel, ibasis), jpos)
            end do
        end do

    end subroutine init_excitations

    subroutine end_excitations(excit_mask)

        ! Deallocate excit_mask.

        use checking, only: check_deallocate

        integer(i0), intent(inout), allocatable :: excit_mask(:,:)

        integer :: ierr

        deallocate(excit_mask, stat=ierr)
        call check_deallocate('excit_mask', ierr)

    end subroutine end_excitations

    pure function get_excitation(nel, basis, f1, f2) result(excitation)

        ! In:
        !    nel: number of electrons in system.
        !    basis: information about the single-particle basis.
        !    f1(tot_string_len): bit string representation of the Slater
        !        determinant.
        !    f2(tot_string_len): bit string representation of the Slater
        !        determinant.
        ! Returns:
        !    excitation: excit_t type containing the following information---
        !        excitation%nexcit: excitation level.
        !
        !    If the excitation is a single or double excitation then it also
        !    includes:
        !
        !        excitation%from_orb(2): orbitals excited from in f1.
        !        excitation%to_orb(2): orbitals excited to in f2.
        !        excitation%perm: true if an odd number of permutations are
        !            reqiured to align the determinants.
        !        The second element of from_orb and to_orb is zero for single
        !        excitations.

        use bit_utils
        use basis_types, only: basis_t

        type(excit_t) :: excitation
        integer, intent(in) :: nel
        type(basis_t), intent(in) :: basis
        integer(i0), intent(in) :: f1(basis%tot_string_len), f2(basis%tot_string_len)
        integer :: i, j, iexcit1, iexcit2, perm, iel1, iel2, shift, nset_bits
        logical :: test_f1, test_f2

        excitation = excit_t(0, 0, 0, .false.)

        if (any(f1/=f2)) then

            iexcit1 = 0
            iexcit2 = 0
            iel1 = 0
            iel2 = 0
            perm = 0

            ! Excitation level...
            excitation%nexcit = sum(count_set_bits(ieor(f1(:basis%bit_string_len),f2(:basis%bit_string_len))))/2

            ! Finding the permutation to align the determinants is non-trivial.
            ! It turns out to be quite easy with bit operations.
            ! The idea is to do a "dumb" permutation where the determinants are
            ! expressed in two sections: orbitals not involved in the excitation
            ! and those that are.  Each section is stored in ascending index
            ! order.
            ! To obtain such ordering requires (for each orbital that is
            ! involved in the excitation) a total of
            ! nel - iel - nexcit + iexcit
            ! where nel is the number of electrons, iel is the position of the
            ! orbital within the list of occupied states in the determinant,
            ! nexcit is the total number of excitations and iexcit is the number
            ! of the "current" orbital involved in excitations.
            ! e.g. Consider (1, 2, 3, 4, 5) -> (1, 3, 5, 6, 7).
            ! (1, 2, 3, 4) goes to (1, 3, 2, 4).
            ! 2 is the first (iexcit=1) orbital found involved in the excitation
            ! and so requires 5 - 2 - 2 + 1 = 2 permutation to shift it to the
            ! first "slot" in the excitation "block" in the list of states.
            ! 4 is the second orbital found and requires 5 - 4 - 2 + 2 = 1
            ! permutations to shift it to the end (last "slot" in the excitation
            ! block).
            ! Whilst the resultant number of permutations isn't necessarily the
            ! minimal number for the determinants to align, this is irrelevant
            ! as the Slater--Condon rules only care about whether the number of
            ! permutations is even or odd.
            shift = nel - excitation%nexcit

            if (excitation%nexcit <= 2) then

                do i = 1, basis%bit_string_len
                    ! Bonus optimisation: We can skip most of the following for
                    ! this element of the bit strings if they are equal, but
                    ! may have to update iel1 and iel2 first...
                    if (f1(i) == f2(i)) then
                        ! If iexcit1-excit2 is even then we don't need to
                        ! update iel1 and iel2, since any error introduced into
                        ! perm by not doing so will be included an even number
                        ! of times, and so won't alter the parity.
                        if (modulo(iexcit1-iexcit2,2) == 1) then
                            nset_bits = count_set_bits(f1(i))
                            iel1 = iel1 + nset_bits
                            iel2 = iel2 + nset_bits
                        end if
                        cycle
                    end if

                    do j = 0, i0_end

                        test_f1 = btest(f1(i),j)
                        test_f2 = btest(f2(i),j)

                        if (test_f2) iel2 = iel2 + 1

                        if (test_f1) then
                            iel1 = iel1 + 1
                            if (.not.test_f2) then
                                ! occupied in f1 but not in f2
                                iexcit1 = iexcit1 + 1
                                excitation%from_orb(iexcit1) = basis%basis_lookup(j,i)
                                perm = perm + (shift - iel1 + iexcit1)
                            end if
                        else
                            if (test_f2) then
                                ! occupied in f1 but not in f2
                                iexcit2 = iexcit2 + 1
                                excitation%to_orb(iexcit2) = basis%basis_lookup(j,i)
                                perm = perm + (shift - iel2 + iexcit2)
                            end if
                        end if

                    end do
                end do

                ! It seems that this test is faster than btest(perm,0)!
                excitation%perm = mod(perm,2) == 1

            end if
        end if

    end function get_excitation

    pure function get_excitation_level(f1, f2) result(level)

        ! Function to obtain the relative excitation level of f1 and f2.
        ! f1 and f2 should have any additional information cleared from
        ! their bit string before being passed in.

        ! In:
        !    f1(bit_string_len): bit string representation of the Slater
        !        determinant.
        !    f2(bit_string_len): bit string representation of the Slater
        !        determinant.
        ! Returns:
        !    Excitation level connecting determinants f1 and f2.

        use bit_utils, only: count_set_bits

        integer :: level
        integer(i0), intent(in) :: f1(:), f2(:)

        level = sum(count_set_bits(ieor(f1,f2)))/2

    end function get_excitation_level

    function det_string(f0, basis) result(determinant_string)
        ! Function to obtain the bit string representation of a Slater determinant.
        
        ! In:
        !    f0(tot_string_len): bit string representation of the determinant with 
        !        excitation information.
        !    basis: information about the 1 particle basis.

        ! Out:
        !    string(bit_string_len): pointer to bit string representation of the determinant
        !        without added information.
        use basis_types, only: basis_t
    
        type(basis_t), intent(in) :: basis
        integer(i0), target, intent(in) :: f0(:)
        integer(i0), pointer :: determinant_string(:)

        determinant_string => f0(:basis%bit_string_len)
     
    end function


    pure subroutine find_excitation_permutation1(excit_mask, f, excitation)

        ! Find the parity of the permutation required to maximally line up
        ! a determinant with an excitation of it, as needed for use with the
        ! Slater--Condon rules.
        !
        ! This version is for single excitations of a determinant.
        !
        ! In:
        !    excit_mask: bit-field mask as created in init_excitations.
        !    f: bit string representation of the determinant.
        !    excitation: excit_t type specifying how the excited determinant is
        !        connected to the determinant given in occ_list.
        ! Out:
        !    excitation: excit_t type with the parity of the permutation also
        !        specified.

        use bit_utils, only: count_set_bits

        integer(i0), intent(in) :: excit_mask(:,:), f(:)
        type(excit_t), intent(inout) :: excitation

        integer :: perm
        integer(i0) :: ia(size(f))

        ! This is just a simplification of find_excitation_permutation2.  See
        ! the comments there (and ignore any that refer to j and b...).

        ia = ieor(excit_mask(:,excitation%from_orb(1)),excit_mask(:,excitation%to_orb(1)))
        perm = sum(count_set_bits(iand(f,ia)))
        if (excitation%from_orb(1) > excitation%to_orb(1)) perm = perm - 1
        excitation%perm = mod(perm,2) == 1

    end subroutine find_excitation_permutation1

    pure subroutine find_excitation_permutation2(excit_mask, f, excitation)

        ! Find the parity of the permutation required to maximally line up
        ! a determinant with an excitation of it, as needed for use with the
        ! Slater--Condon rules.
        !
        ! This version is for double excitations of a determinant.
        !
        ! In:
        !    excit_mask: bit-field mask as created in init_excitations.
        !    f: bit string representation of the determinant.
        !    excitation: excit_t type specifying how the excited determinant is
        !        connected to the determinant described by f.
        !        Note that we require the lists of orbitals excited from/into to
        !        be ordered.
        ! Out:
        !    excitation: excit_t type with the parity of the permutation also
        !        specified.

        use bit_utils, only: count_set_bits

        integer(i0), intent(in) :: excit_mask(:,:), f(:)
        type(excit_t), intent(inout) :: excitation

        integer :: perm
        integer(i0) :: ia(size(f)), jb(size(f))

        ! Fast way of getting the parity of the permutation required to align
        ! two determinants given one determinant and the connecting exctitation.
        ! This is hard to generalise to all cases, but we actually only care
        ! about single and double excitations.  The idea is quite different from
        ! that used in get_excitation (where we also need to find the orbitals
        ! involved in the excitation).

        ! In the following & represents the bitwise and operation; ^ the bitwise exclusive or
        ! operation; xmask is a mask with all bits representing orbitals above
        ! x set; f is the string representing the determinant from which we
        ! excite and the excitation is defined by (i,j)->(a,b), where i<j and
        ! a<b.

        ! imask ^ amask returns a bit string with bits corresponding to all
        ! orbitals between i and a set, with max(i,a) set and min(i,a) cleared.
        ! Thus f & (imask ^ amask) returns a bit string with only bits set for
        ! the occupied orbitals which are between i and a (possibly including i)
        ! and so the popcount of this gives the number of orbitals between i and
        ! a (possibly one larger than the actual answer) number of permutations needed to
        ! align i and a in the same 'slot' in the determinant string.  We need
        ! to subtract one if i>a to correct for the overcounting.

        ! An analagous approach counts the number of permutations required so
        ! j and b are coincident.

        ! We need to account for some more overcounting/undercounting.
        ! If j is between i and a, then it is counted yet j can either be moved
        ! before i (resulting in the actual number of permutations being one
        ! less than that counted) or after i (resulting in moving j taking one
        ! more permutation than counted).  Technically it doesn't matter which
        ! we do, as we are only interested in whether the number of permutations
        ! is odd or even.  We similarly need to take into account the case where
        ! i is between j and b.

        ! Finally, we note that we don't care about the exact number of
        ! permutations but only the parity.  Hence the exclusive or of the
        ! occupied orbitals between i and a and the occupied orbitals between
        ! j and b gives the occupied orbitals which are only involved in one
        ! permutation but not two.  This enables us to use only one popcount.
        ! However, we need to add one for the undercounting/overcounting issues
        ! to avoid the number of counted permutations becoming negative!

        ia = ieor(excit_mask(:,excitation%from_orb(1)),excit_mask(:,excitation%to_orb(1)))
        jb = ieor(excit_mask(:,excitation%from_orb(2)),excit_mask(:,excitation%to_orb(2)))

        perm = sum(count_set_bits(ieor(iand(f,ia),iand(f,jb))))

        if (excitation%from_orb(1) > excitation%to_orb(1)) perm = perm + 1
        if (excitation%from_orb(1) > excitation%to_orb(2)) perm = perm + 1
        if (excitation%from_orb(2) > excitation%to_orb(2) .or. &
            excitation%from_orb(2) < excitation%to_orb(1)) perm = perm + 1

        excitation%perm = mod(perm,2) == 1

    end subroutine find_excitation_permutation2

    pure subroutine create_excited_det(basis, f_in, connection, f_out)

        ! Generate a determinant from another determinant and the excitation
        ! information connecting the two determinants.
        ! Information bits are not set correctly on output of f_out.

        ! In:
        !    basis: information about the single-particle basis.
        !    f_in(tot_string_len): bit string representation of the reference
        !        Slater determinant.
        !    connection: excitation connecting f_in to f_out.  Note that
        !        the perm field is not used.
        ! Out:
        !    f_out(tot_string_len): bit string representation of the excited
        !        Slater determinant.

        use basis_types, only: basis_t

        type(basis_t), intent(in) :: basis
        integer(i0), intent(in) :: f_in(basis%tot_string_len)
        type(excit_t), intent(in) :: connection
        integer(i0), intent(out) :: f_out(basis%tot_string_len)

        integer :: i, orb, bit_pos, bit_element

        ! Unset the orbitals which are excited from and set the orbitals which
        ! are excited into.
        f_out = f_in
        do i = 1, connection%nexcit
            ! Clear i/j orbital.
            orb = connection%from_orb(i)
            bit_pos = basis%bit_lookup(1,orb)
            bit_element = basis%bit_lookup(2,orb)
            f_out(bit_element) = ibclr(f_out(bit_element), bit_pos)
            ! Set a/b orbital.
            orb = connection%to_orb(i)
            bit_pos = basis%bit_lookup(1,orb)
            bit_element = basis%bit_lookup(2,orb)
            f_out(bit_element) = ibset(f_out(bit_element), bit_pos)
        end do

    end subroutine create_excited_det

    pure function in_ras(ras1_mask, ras3_mask, nelec1, nelec3, f)

        ! In:
        !    ras1_mask: bit mask containing the orbitals in the RAS1 space.
        !    ras3_mask: bit mask containing the orbitals in the RAS3 space.
        !    nelec1: minimum number of electrons allowed in the RAS1 space.
        !    nelec3: maximum number of electrons allowed in the RAS3 space.
        !    f: bit string of determinant.

        ! Returns:
        !    True if determinant is inside the restricted active space.

        ! Note: the RAS2 space (if it exists) lies between RAS1 and RAS3 and
        ! can, like a CAS, contain an arbitrary number of electrons.

        use bit_utils, only: count_set_bits

        logical :: in_ras
        integer(i0), intent(in) :: ras1_mask(:), ras3_mask(:), f(:)
        integer, intent(in) :: nelec1, nelec3

        in_ras = sum(count_set_bits(iand(f, ras1_mask))) >= nelec1 .and. sum(count_set_bits(iand(f, ras3_mask))) <= nelec3

    end function in_ras

    pure function connection_exists(sys) result(exists)

        ! This function returns true if at least one excitation with a
        ! non-zero Hamiltonian matrix element exists, based on simple
        ! criteria (it only considers the total number of alpha and beta
        ! orbitals, and not symmetry label considerations).

        ! In:
        !    sys: sys_t object containing the system parameters to be
        !        considered.
        ! Returns:
        !    exist: true if at least one connection exists, false otherwise.

        use system, only: sys_t, heisenberg

        type(sys_t), intent(in) :: sys
        logical :: exists

        exists = .true.

        select case (sys%system)
        case(heisenberg)
            ! In the Heisenberg model, nel is the number of up spins on the
            ! lattice. This number must be conserved in all connections.
            exists = .not. ((sys%nel == 0) .or. (sys%nel == sys%basis%nbasis))
        case default
            ! Are there any remaining alpha or beta orbitals to excite to?
            if (sys%nalpha == 0 .and. sys%nvirt_beta == 0) exists = .false.
            if (sys%nbeta == 0 .and. sys%nvirt_alpha == 0) exists = .false.
            if (sys%nel == 0 .or. sys%nel == sys%basis%nbasis) exists = .false.
        end select

    end function connection_exists

    pure subroutine get_excitation_locations(ref_list, det_list, ref_store, det_store, nel, nexcit)

        ! Given lists of nel orbitals, ref_list and det_list, determine the indices of
        ! the orbitals in these which cannot be paired up and place each in the appropriate _store

        ! In:
        !    ref_list: integer list of nel occupied orbitals
        !    det_list: integer list of nel occupied orbitals
        !    nel:  number of electrons
        ! Out:
        !    nexcit:  The number of differences
        !    ref_store(1:nexcit): the indices of the different orbitals in ref. 
        !    det_store(1:nexcit): the indices of the different orbitals in det.
        
        ! Note: ref and cdet are assumed to be ordered.
        ! This procedure is O(nel)

        integer, intent(in) :: nel
        integer, intent(in) :: ref_list(nel)
        integer, intent(in) :: det_list(nel)
        integer, intent(out) :: ref_store(nel)
        integer, intent(out) :: det_store(nel)
        integer, intent(out) :: nexcit

        integer :: i, j, det_sind, ref_sind, i_backwards, i_backwards_position

        j = 1  ! This is the index in det_list.

        ! det_store contains a list of positions within det_list of the orbitals which are non-matching.
        ! similarly with ref_store
        det_sind = 0 ! the position in cdet_store of the last non-matching orbital
        ref_sind = 0 ! the position in ref_store of the last non-matching orbital

        ! [todo] - Consider sorting these lists by spin.

fdo:    do i=1, nel ! this will index in ref
            do while (det_list(j)<ref_list(i))
                ! det's orb isn't in ref, so we store its index in det_store
                det_sind = det_sind + 1
                det_store(det_sind) = j
                j = j + 1
                if (j > nel)  exit fdo 
            end do
            if (det_list(j)>ref_list(i)) then
                ! ref's orb isn't in det, so store that
                ref_sind = ref_sind + 1
                ref_store(ref_sind) = i
            else
                ! both are equal so we increment j
                j = j + 1
            end if
            if (j > nel) exit fdo
        end do fdo 
        
        ! Deal with whatever's left in det. j is the NEXT orbital to  deal with.
        do while (j<=nel)
            det_sind = det_sind + 1
            det_store(det_sind) = j
            j = j + 1
        end do

        ! Deal with whatever's left over in ref.  i is currently the last orbital we dealt with.
        ! We fill this up backwards as having filled up j
        ! we know the final value of ref_sind (= det_sind).
        i_backwards = nel
        i_backwards_position = det_sind
        do while (ref_sind < det_sind)
            ref_store(i_backwards_position) = i_backwards
            i_backwards = i_backwards - 1
            i_backwards_position = i_backwards_position - 1
            ref_sind = ref_sind + 1
        end do


        nexcit = ref_sind

    end subroutine get_excitation_locations

end module excitations
