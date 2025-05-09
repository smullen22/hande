system = {
    int_file = "FCIDUMP",
    nel = 24,
    ms = 0,
    sym = "aufbau",
    complex = true,
}

sys = read_in(system)

ccmc {
    sys = sys,
    qmc = {
        tau = 5e-4,
        rng_seed = 23,
        init_pop = 1000,
        mc_cycles = 20,
        real_amplitudes = true,
        nreports = 20,
        target_population = 12500,
        state_size = 12000,
        spawned_state_size = 15000,
    },
    reference = {
        ex_level = 3,
    },
    ccmc = {
        full_non_composite = true,
        even_selection = true,
    },
    restart = {
        write = 1,
        write_shift = 0,
    },
}
