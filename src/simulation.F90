module simulation

  use, intrinsic :: ISO_C_BINDING

#ifdef _OPENMP
  use omp_lib
#endif

  use bank_header,     only: source_bank
  use cmfd_execute,    only: cmfd_init_batch, cmfd_tally_init, execute_cmfd
  use cmfd_header,     only: cmfd_on
  use constants,       only: ZERO
  use eigenvalue,      only: calculate_average_keff, calculate_generation_keff, &
                             k_sum
#ifdef _OPENMP
  use eigenvalue,      only: join_bank_from_threads
#endif
  use error,           only: fatal_error, write_message
  use geometry_header, only: n_cells
  use material_header, only: n_materials, materials
  use message_passing
  use mgxs_interface,  only: energy_bins, energy_bin_avg
  use nuclide_header,  only: micro_xs, n_nuclides
  use output,          only: header, print_columns, &
                             print_batch_keff, print_generation, print_runtime, &
                             print_results, write_tallies
  use particle_header
  use photon_header,   only: micro_photon_xs, n_elements
  use random_lcg,      only: set_particle_seed
  use settings
  use simulation_header
  use state_point,     only: openmc_statepoint_write, write_source_point, load_state_point
  use string,          only: to_str
  use tally,           only: accumulate_tallies, setup_active_tallies, &
                             init_tally_routines
  use tally_header
  use tally_filter_header, only: filter_matches, n_filters
  use tally_derivative_header, only: tally_derivs
  use timer_header
  use trigger,         only: check_triggers
  use tracking,        only: transport

  implicit none
  private
  public :: openmc_next_batch
  public :: openmc_simulation_init
  public :: openmc_simulation_finalize

  integer(C_INT), parameter :: STATUS_EXIT_NORMAL = 0
  integer(C_INT), parameter :: STATUS_EXIT_MAX_BATCH = 1
  integer(C_INT), parameter :: STATUS_EXIT_ON_TRIGGER = 2

  interface
    subroutine openmc_simulation_init_c() bind(C)
    end subroutine

    subroutine initialize_source() bind(C)
    end subroutine

    subroutine initialize_generation() bind(C)
    end subroutine

    function sample_external_source() result(site) bind(C)
      import Bank
      type(Bank) :: site
    end function
  end interface

contains

!===============================================================================
! OPENMC_NEXT_BATCH
!===============================================================================

  function openmc_next_batch(status) result(err) bind(C)
    integer(C_INT), intent(out), optional :: status
    integer(C_INT) :: err

    type(Particle) :: p
    integer(8)     :: i_work

    err = 0

    ! Make sure simulation has been initialized
    if (.not. simulation_initialized) then
      err = E_ALLOCATE
      call set_errmsg("Simulation has not been initialized yet.")
      return
    end if

    call initialize_batch()

    ! =======================================================================
    ! LOOP OVER GENERATIONS
    GENERATION_LOOP: do current_gen = 1, gen_per_batch

      call initialize_generation()

      ! Start timer for transport
      call time_transport % start()

      ! ====================================================================
      ! LOOP OVER PARTICLES
!$omp parallel do schedule(runtime) firstprivate(p) copyin(tally_derivs)
      PARTICLE_LOOP: do i_work = 1, work
        current_work = i_work

        ! grab source particle from bank
        call initialize_history(p, current_work)

        ! transport particle
        call transport(p)

      end do PARTICLE_LOOP
!$omp end parallel do

      ! Accumulate time for transport
      call time_transport % stop()

      call finalize_generation()

    end do GENERATION_LOOP

    call finalize_batch()

    ! Check simulation ending criteria
    if (present(status)) then
      if (current_batch == n_max_batches) then
        status = STATUS_EXIT_MAX_BATCH
      elseif (satisfy_triggers) then
        status = STATUS_EXIT_ON_TRIGGER
      else
        status = STATUS_EXIT_NORMAL
      end if
    end if

  end function openmc_next_batch

!===============================================================================
! INITIALIZE_HISTORY
!===============================================================================

  subroutine initialize_history(p, index_source)

    type(Particle), intent(inout) :: p
    integer(8),     intent(in)    :: index_source

    integer(8) :: particle_seed  ! unique index for particle
    integer :: i

    ! set defaults
    call particle_from_source(p, source_bank(index_source), run_CE, &
         energy_bin_avg)

    ! set identifier for particle
    p % id = work_index(rank) + index_source

    ! set random number seed
    particle_seed = (total_gen + overall_generation() - 1)*n_particles + p % id
    call set_particle_seed(particle_seed)

    ! set particle trace
    trace = .false.
    if (current_batch == trace_batch .and. current_gen == trace_gen .and. &
         p % id == trace_particle) trace = .true.

    ! Set particle track.
    p % write_track = .false.
    if (write_all_tracks) then
      p % write_track = .true.
    else if (allocated(track_identifiers)) then
      do i=1, size(track_identifiers(1,:))
        if (current_batch == track_identifiers(1,i) .and. &
             &current_gen == track_identifiers(2,i) .and. &
             &p % id == track_identifiers(3,i)) then
          p % write_track = .true.
          exit
        end if
      end do
    end if

  end subroutine initialize_history

!===============================================================================
! INITIALIZE_BATCH
!===============================================================================

  subroutine initialize_batch()

    integer :: i

    ! Increment current batch
    current_batch = current_batch + 1

    if (run_mode == MODE_FIXEDSOURCE) then
      call write_message("Simulating batch " // trim(to_str(current_batch)) &
           // "...", 6)
    end if

    ! Reset total starting particle weight used for normalizing tallies
    total_weight = ZERO

    if ((n_inactive > 0 .and. current_batch == 1) .or. &
         (restart_run .and. restart_batch < n_inactive .and. current_batch == restart_batch + 1)) then
      ! Turn on inactive timer
      call time_inactive % start()
    elseif ((current_batch == n_inactive + 1) .or. &
         (restart_run .and. restart_batch > n_inactive .and. current_batch == restart_batch + 1)) then
      ! Switch from inactive batch timer to active batch timer
      call time_inactive % stop()
      call time_active % start()

      do i = 1, n_tallies
        tallies(i) % obj % active = .true.
      end do
    end if

    ! check CMFD initialize batch
    if (run_mode == MODE_EIGENVALUE) then
      if (cmfd_run) call cmfd_init_batch()
    end if

    ! Add user tallies to active tallies list
    call setup_active_tallies()

  end subroutine initialize_batch

!===============================================================================
! FINALIZE_GENERATION
!===============================================================================

  subroutine finalize_generation()

    interface
      subroutine fill_source_bank_fixedsource() bind(C)
      end subroutine

      subroutine shannon_entropy() bind(C)
      end subroutine

      subroutine synchronize_bank() bind(C)
      end subroutine
    end interface

    ! Update global tallies with the omp private accumulation variables
!$omp parallel
!$omp critical
    if (run_mode == MODE_EIGENVALUE) then
      global_tallies(RESULT_VALUE, K_COLLISION) = &
           global_tallies(RESULT_VALUE, K_COLLISION) + global_tally_collision
      global_tallies(RESULT_VALUE, K_ABSORPTION) = &
           global_tallies(RESULT_VALUE, K_ABSORPTION) + global_tally_absorption
      global_tallies(RESULT_VALUE, K_TRACKLENGTH) = &
           global_tallies(RESULT_VALUE, K_TRACKLENGTH) + global_tally_tracklength
    end if
    global_tallies(RESULT_VALUE, LEAKAGE) = &
         global_tallies(RESULT_VALUE, LEAKAGE) + global_tally_leakage
!$omp end critical

    ! reset private tallies
    if (run_mode == MODE_EIGENVALUE) then
      global_tally_collision = ZERO
      global_tally_absorption = ZERO
      global_tally_tracklength = ZERO
    end if
    global_tally_leakage = ZERO
!$omp end parallel

    if (run_mode == MODE_EIGENVALUE) then
#ifdef _OPENMP
      ! Join the fission bank from each thread into one global fission bank
      call join_bank_from_threads()
#endif

      ! Distribute fission bank across processors evenly
      call synchronize_bank()

      ! Calculate shannon entropy
      if (entropy_on) call shannon_entropy()

      ! Collect results and statistics
      call calculate_generation_keff()
      call calculate_average_keff()

      ! Write generation output
      if (master .and. verbosity >= 7) then
        if (current_gen /= gen_per_batch) then
          call print_generation()
        end if
      end if

    elseif (run_mode == MODE_FIXEDSOURCE) then
      ! For fixed-source mode, we need to sample the external source
      call fill_source_bank_fixedsource()
    end if

  end subroutine finalize_generation

!===============================================================================
! FINALIZE_BATCH handles synchronization and accumulation of tallies,
! calculation of Shannon entropy, getting single-batch estimate of keff, and
! turning on tallies when appropriate
!===============================================================================

  subroutine finalize_batch()

    integer(C_INT) :: err
    character(MAX_FILE_LEN) :: filename

    interface
      subroutine broadcast_triggers() bind(C)
      end subroutine broadcast_triggers
    end interface

    ! Reduce tallies onto master process and accumulate
    call time_tallies % start()
    call accumulate_tallies()
    call time_tallies % stop()

    ! Reset global tally results
    if (current_batch <= n_inactive) then
      global_tallies(:,:) = ZERO
      n_realizations = 0
    end if

    if (run_mode == MODE_EIGENVALUE) then
      ! Perform CMFD calculation if on
      if (cmfd_on) call execute_cmfd()
      ! Write batch output
      if (master .and. verbosity >= 7) call print_batch_keff()
    end if

    ! Check_triggers
    if (master) call check_triggers()
#ifdef OPENMC_MPI
    call broadcast_triggers()
#endif
    if (satisfy_triggers .or. &
         (trigger_on .and. current_batch == n_max_batches)) then
      call statepoint_batch % add(current_batch)
    end if

    ! Write out state point if it's been specified for this batch
    if (statepoint_batch % contains(current_batch)) then
      if (sourcepoint_batch % contains(current_batch) .and. source_write &
           .and. .not. source_separate) then
        err = openmc_statepoint_write(write_source=.true._C_BOOL)
      else
        err = openmc_statepoint_write(write_source=.false._C_BOOL)
      end if
    end if

    ! Write out a separate source point if it's been specified for this batch
    if (sourcepoint_batch % contains(current_batch) .and. source_write &
         .and. source_separate) call write_source_point()

    ! Write a continously-overwritten source point if requested.
    if (source_latest) then
      filename = trim(path_output) // 'source' // '.h5'
      call write_source_point(filename)
    end if

  end subroutine finalize_batch


!===============================================================================
! INITIALIZE_SIMULATION
!===============================================================================

  function openmc_simulation_init() result(err) bind(C)
    integer(C_INT) :: err

    integer :: i

    err = 0

    ! Skip if simulation has already been initialized
    if (simulation_initialized) return

    ! Call initialization on C++ side
    call openmc_simulation_init_c()

    ! Set up tally procedure pointers
    call init_tally_routines()

    ! Allocate source bank, and for eigenvalue simulations also allocate the
    ! fission bank
    call allocate_banks()

    ! Allocate tally results arrays if they're not allocated yet
    call configure_tallies()

    ! Activate the CMFD tallies
    call cmfd_tally_init()

    ! Set up material nuclide index mapping
    do i = 1, n_materials
      call materials(i) % init_nuclide_index()
    end do

!$omp parallel
    ! Allocate array for microscopic cross section cache
    allocate(micro_xs(n_nuclides))
    allocate(micro_photon_xs(n_elements))

    ! Allocate array for matching filter bins
    allocate(filter_matches(n_filters))
    do i = 1, n_filters
      allocate(filter_matches(i) % bins)
      allocate(filter_matches(i) % weights)
    end do
!$omp end parallel

    ! Reset global variables -- this is done before loading state point (as that
    ! will potentially populate k_generation and entropy)
    current_batch = 0
    call k_generation_clear()
    call entropy_clear()
    need_depletion_rx = .false.

    ! If this is a restart run, load the state point data and binary source
    ! file
    if (restart_run) then
      call load_state_point()
      call write_message("Resuming simulation...", 6)
    else
      call initialize_source()
    end if

    ! Display header
    if (master) then
      if (run_mode == MODE_FIXEDSOURCE) then
        call header("FIXED SOURCE TRANSPORT SIMULATION", 3)
      elseif (run_mode == MODE_EIGENVALUE) then
        call header("K EIGENVALUE SIMULATION", 3)
        if (verbosity >= 7) call print_columns()
      end if
    end if

    ! Set flag indicating initialization is done
    simulation_initialized = .true.

  end function openmc_simulation_init

!===============================================================================
! FINALIZE_SIMULATION calculates tally statistics, writes tallies, and displays
! execution time and results
!===============================================================================

  function openmc_simulation_finalize() result(err) bind(C)
    integer(C_INT) :: err

    integer    :: i       ! loop index

    interface
      subroutine print_overlap_check() bind(C)
      end subroutine print_overlap_check

      subroutine broadcast_results() bind(C)
      end subroutine broadcast_results
    end interface

    err = 0

    ! Skip if simulation was never run
    if (.not. simulation_initialized) return

    ! Stop active batch timer and start finalization timer
    call time_active % stop()
    call time_finalize % start()

    ! Free up simulation-specific memory
    do i = 1, n_materials
      deallocate(materials(i) % mat_nuclide_index)
    end do
!$omp parallel
    do i = 1, size(filter_matches)
      deallocate(filter_matches(i) % bins)
      deallocate(filter_matches(i) % weights)
    end do
    deallocate(micro_xs, micro_photon_xs, filter_matches)
!$omp end parallel

    ! Increment total number of generations
    total_gen = total_gen + current_batch*gen_per_batch

#ifdef OPENMC_MPI
    call broadcast_results()
#endif

    ! Write tally results to tallies.out
    if (output_tallies .and. master) call write_tallies()

    ! Deactivate all tallies
    if (allocated(tallies)) then
      do i = 1, n_tallies
        tallies(i) % obj % active = .false.
      end do
    end if

    ! Stop timers and show timing statistics
    call time_finalize%stop()
    call time_total%stop()
    if (master) then
      if (verbosity >= 6) call print_runtime()
      if (verbosity >= 4) call print_results()
    end if
    if (check_overlaps) call print_overlap_check()

    ! Reset flags
    need_depletion_rx = .false.
    simulation_initialized = .false.

  end function openmc_simulation_finalize

!===============================================================================
! ALLOCATE_BANKS allocates memory for the fission and source banks
!===============================================================================

  subroutine allocate_banks()

    integer :: alloc_err  ! allocation error code

    ! Allocate source bank
    if (allocated(source_bank)) deallocate(source_bank)
    allocate(source_bank(work), STAT=alloc_err)

    ! Check for allocation errors
    if (alloc_err /= 0) then
      call fatal_error("Failed to allocate source bank.")
    end if

    if (run_mode == MODE_EIGENVALUE) then

#ifdef _OPENMP
      ! If OpenMP is being used, each thread needs its own private fission
      ! bank. Since the private fission banks need to be combined at the end of
      ! a generation, there is also a 'master_fission_bank' that is used to
      ! collect the sites from each thread.

      n_threads = omp_get_max_threads()

!$omp parallel
      thread_id = omp_get_thread_num()

      if (allocated(fission_bank)) deallocate(fission_bank)
      if (thread_id == 0) then
        allocate(fission_bank(3*work))
      else
        allocate(fission_bank(3*work/n_threads))
      end if
!$omp end parallel
      if (allocated(master_fission_bank)) deallocate(master_fission_bank)
      allocate(master_fission_bank(3*work), STAT=alloc_err)
#else
      if (allocated(fission_bank)) deallocate(fission_bank)
      allocate(fission_bank(3*work), STAT=alloc_err)
#endif

      ! Check for allocation errors
      if (alloc_err /= 0) then
        call fatal_error("Failed to allocate fission bank.")
      end if
    end if

  end subroutine allocate_banks

end module simulation
