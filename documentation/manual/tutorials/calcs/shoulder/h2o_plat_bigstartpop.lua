sys = read_in {
    int_file = "H2O_INTDUMP",
    nel = 10,
    ms = 0,
}

ccmc {
    sys = sys,
    qmc = {
        tau = 1e-4,
        mc_cycles = 10,
        nreports = 2e4,
        state_size = -500,
        spawned_state_size = -200,
        init_pop = 800,
        real_amplitudes = true,
	target_population = 3e5,
    },
    reference = {
        ex_level = 3,
    },
}
