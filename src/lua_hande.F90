module lua_hande

! A lua interface to HANDE using the AOTUS library.

! A very quick tutorial/summary/notes on interacting with lua:

! 1. Please read the Lua manual on the C API: http://www.lua.org/pil/24.html.
! 2. aotus has many useful wrappers around the Lua C API for interacting with Lua,
!    including transferring information from Fortran to Lua and vice versa.  See
!    lib/aotus/source for the wrapper functions.
! 3. Everything goes via the Lua stack, which is a C pointer (Fortran)/Lua_State* (C).
!    aotus wraps this into a flu_State object, which we should use wherever possible (ie
!    always).
! 4. Note that each function called by lua gets its own private stack.
! 5. The Lua stack is LIFO (last in, first out), so the first argument passed is at the
!    bottom of the stack and the last argument at the top.  Similarly the first argument
!    returned is at the bottom of the stack and the last argument at the top.
! 6. A function can be called from lua if it is 'registered' with the Lua stack and has
!    a very specific interface, e.g.:
!
!        function test_lua_api(L) result(nreturn) bind(c)
!
!            ! Example function callable from a Lua script.
!            ! Must be bind(C) so it can be called from C/Lua.
!            ! Must take a C pointer (which is a Lua stack) as the sole argument.
!            ! Must return an integer which is the number of variables the
!            ! function returns to Lua by pushing to the stack.
!
!            ! In/Out:
!            !    L: lua state (bare C pointer).
!
!            use flu_binding, only: flu_State, flu_copyptr
!            use, intrinsic :: iso_c_binding, only: c_ptr, c_int
!
!            integer(c_int) :: nreturn
!            type(c_ptr), value :: L
!
!            type(flu_State) :: lua_state
!
!            ! Create flu_state from lua state so we can use the nice bindings
!            ! provided by AOTUS.
!            lua_state = flu_copyptr(L)
!
!            ! Number of variables returned on lua stack.
!            nreturn = 0
!
!            ! Get arguments passed to us by lua (if appropriate).
!
!            ! Now do our work...
!            write (6,'(1X,"Hello from fortran!",/)')
!
!        end function test_lua_api
!
! 7. The function can the be called in lua using function_name(arg1, arg2, ...).  In the
!    example above, there are no arguments so it's simply test_lua_api(), assuming
!    test_lua_api is the name provided to lua in the flu_register call.
! 8. Please read the lua documentation and see the examples in the lua_hande* files for
!    more details!

implicit none

contains

    subroutine run_lua_hande()

        ! Generic entry point from which a lua script is run.

        use aotus_module, only: open_config_chunk
        use flu_binding, only: flu_State, fluL_newstate, flu_close
        use lua_hande_utils, only: timing_summary

        use errors, only: stop_all, warning
        use parallel
        use utils, only: read_file_to_buffer

        character(255) :: inp_file, err_string
        character(:), allocatable :: buffer
        integer :: lua_err
        integer :: buf_len
        type(flu_State) :: lua_state
        logical :: t_exists
#ifdef PARALLEL
        integer :: ierr
#endif

        if (command_argument_count() > 0) then

            ! Read input file on parent and broadcast to all other processors.
            if (parent) then
                call get_command_argument(1, inp_file)
                inquire(file=inp_file, exist=t_exists)
                if (.not.t_exists) call stop_all('run_hande_lua','File does not exist:'//trim(inp_file))

                write (6,'(a14,/,1X,13("-"),/)') 'Input options'
                call read_file_to_buffer(buffer, inp_file)
                write (6,'(A)') trim(buffer)
                buf_len = len(buffer)
                write (6,'(/,1X,13("-"),/)')
            end if

#ifdef PARALLEL
            call mpi_bcast(buf_len, 1, MPI_INTEGER, 0, mpi_comm_world, ierr)
            if (.not.parent) allocate(character(len=buf_len) :: buffer)
            call mpi_bcast(buffer, buf_len, MPI_CHARACTER, 0, mpi_comm_world, ierr)
#endif

            ! Attempt to run lua script.
            lua_state = fluL_newstate()
            call register_lua_hande_api(lua_state)

            call open_config_chunk(lua_state, buffer, lua_err, err_string)
            if (lua_err == 0) then
                call timing_summary(lua_state)
                call flu_close(lua_state)
            else
                write (6,*) 'aotus/lua error code:', lua_err
                call stop_all('run_lua_hande', trim(err_string))
            end if

#ifdef PARALLEL
            call mpi_barrier(mpi_comm_world, ierr)
#endif

        else if (parent) then
            call stop_all('run_lua_hande', 'No input file supplied.')
        end if

    end subroutine run_lua_hande

    subroutine register_lua_hande_api(lua_state)

        ! Register HANDE functions which are exposed to Lua scripts with a Lua state
        ! so that they can be called from a Lua script loaded by the same Lua state.

        ! In/Out:
        !    lua_state: flu/Lua state to which the HANDE API is added.

        use flu_binding, only: flu_State, flu_register, flu_pushstring, flu_settable, flu_createtable
        use tests, only: test_lua_api

        use lua_hande_system
        use lua_hande_calc
        use lua_hande_fns

        use lua_hande_utils, only: lua_registryindex

        type(flu_State), intent(inout) :: lua_state

        call flu_register(lua_state, 'test_lua_api', test_lua_api)

        ! Utilities
        call flu_register(lua_state, 'mpi_root', mpi_root)

        ! Systems
        call flu_register(lua_state, 'hubbard_k', lua_hubbard_k)
        call flu_register(lua_state, 'hubbard_real', lua_hubbard_real)
        call flu_register(lua_state, 'chung_landau', lua_chung_landau)
        call flu_register(lua_state, 'read_in', lua_read_in)
        call flu_register(lua_state, 'heisenberg', lua_heisenberg)
        call flu_register(lua_state, 'ueg', lua_ueg)
        call flu_register(lua_state, 'ringium', lua_ringium)

        ! Additional functionality
        call flu_register(lua_state, 'write_read_in_system', lua_write_read_in_system)

        ! Calculations
        call flu_register(lua_state, 'fci', lua_fci)
        call flu_register(lua_state, 'hilbert_space', lua_hilbert_space)
        call flu_register(lua_state, 'canonical_estimates', lua_canonical_estimates)
        call flu_register(lua_state, 'mp1_mc', lua_mp1_mc)
        call flu_register(lua_state, 'simple_fciqmc', lua_simple_fciqmc)
        call flu_register(lua_state, 'fciqmc', lua_fciqmc)
        call flu_register(lua_state, 'ccmc', lua_ccmc)
        call flu_register(lua_state, 'uccmc', lua_uccmc)
        call flu_register(lua_state, 'dmqmc', lua_dmqmc)

        ! Helper functions
        call flu_register(lua_state, 'redistribute', lua_redistribute_restart)

        ! Metatables for objects returned to lua
        call create_metatable(lua_state, "sys", lua_dealloc_sys)
        call create_metatable(lua_state, "qmc_state", lua_dealloc_qmc_state)
        call create_metatable(lua_state, "psip_list", lua_dealloc_psip_list)

        ! Timer table in the registry to give a break down of calculation time
        call flu_pushstring(lua_state, "timer")
        call flu_createtable(lua_state, 0, 0)
        call flu_settable(lua_state, lua_registryindex)

    end subroutine register_lua_hande_api

    subroutine create_metatable(lua_state, name, dealloc)

        ! Create a metatable with a name and a finaliser

        ! In/Out;
        !    lua_state: flu/Lua state to which the HANDE API is added.
        ! In:
        !    name: name of metatable/type
        !    dealloc: deallocation function for the type

        use flu_binding, only: flu_State, fluL_newmetatable, flu_pushstring, flu_pushcclosure, flu_settable, flu_pop, lua_function
        use aot_table_ops_module, only: aot_table_top

        type(flu_State), intent(inout) :: lua_state
        character(*), intent(in) :: name
        procedure(lua_Function) :: dealloc

        integer :: metatable, err

        err = fluL_newmetatable(lua_state, name)
        metatable = aot_table_top(lua_state)
        ! Type name.  Note this also protects tables with this metatable from having their metatable changed or accessed.
        call flu_pushstring(lua_state, "__metatable")
        call flu_pushstring(lua_state, name)
        call flu_settable(lua_state, metatable)
        ! Finalisation
        call flu_pushstring(lua_state, "__gc")
        call flu_pushcclosure(lua_state, dealloc, 0)
        call flu_settable(lua_state, metatable)
        call flu_pop(lua_state)

    end subroutine create_metatable

    ! --- Helper functions : lua ---

    function mpi_root(L) result(nreturn) bind(c)

        ! In/Out:
        !    L: lua state (bare C pointer).

        ! Lua:
        !    mpi_root()
        ! Returns:
        !    True if on the MPI root processor.

        use, intrinsic :: iso_c_binding, only: c_ptr, c_int
        use parallel, only: parent
        use flu_binding, only: flu_State, flu_copyptr, flu_pushboolean

        integer(c_int) :: nreturn
        type(c_ptr), value :: L
        type(flu_State) :: lua_state

        lua_state = flu_copyptr(L)
        call flu_pushboolean(lua_state, parent)
        nreturn = 1

    end function mpi_root

end module lua_hande
