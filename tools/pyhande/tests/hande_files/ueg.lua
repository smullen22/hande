-- Create output with:
-- $[HANDE DIR]/bin/hande.x ueg.lua > ueg.out 2> ueg.err
-- Note that these settings are just for testing...
sys = ueg {
    dim = 3,
    nel = 14,
    ms = 0,
    cutoff = 1,
}

fciqmc {
    sys = sys,
    qmc = {
        tau = 0.1,
        rng_seed = 1472,
        init_pop = 2,
        mc_cycles = 10,
        nreports = 3,
        target_population = 60,
        state_size = 50000,
        spawned_state_size = 5000,
    },
}
