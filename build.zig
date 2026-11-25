const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: safe)",
    ) orelse .safe;

    const mod = b.addModule("zig_vcs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zig_vcs",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zig_vcs" is the name you will use in your source code to
                // import this module (e.g. `@import("zig_vcs")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zig_vcs", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Non-installed developer verification, fuzzing & benchmark executable (`zig build prove|fuzz|bench|profile`).
    // Keeps test/verification harnesses out of the installed `zig_vcs` CLI binary.
    const verify_exe = b.addExecutable(.{
        .name = "zig_vcs_verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_vcs", .module = mod },
            },
        }),
    });

    // Formal verification step: runs Lean 4 theorem prover (`lake build` in `proofs/`)
    // alongside the Zig-native TLA+ explicit-state model checker tests.
    const lean_cmd = b.addSystemCommand(&.{ "lake", "build" });
    lean_cmd.setCwd(b.path("proofs"));

    const prove_cmd = b.addRunArtifact(verify_exe);
    prove_cmd.addArg("prove");

    const prove_step = b.step("prove", "Run Lean 4 formal proofs and Zig TLA+ model checker");
    prove_step.dependOn(&lean_cmd.step);
    prove_step.dependOn(&run_mod_tests.step);
    prove_step.dependOn(&prove_cmd.step);

    const fuzz_cmd = b.addRunArtifact(verify_exe);
    fuzz_cmd.addArg("fuzz");
    fuzz_cmd.addPassthruArgs();
    const fuzz_step = b.step("fuzz", "Run 1,500-step Differential Conformance Fuzzer & Crash Recovery Harness");
    fuzz_step.dependOn(&fuzz_cmd.step);

    const bench_cmd = b.addRunArtifact(verify_exe);
    bench_cmd.addArg("bench");
    bench_cmd.addPassthruArgs();
    const bench_step = b.step("bench", "Run CPU Profiler and Complex Repository Benchmark Suite");
    bench_step.dependOn(&bench_cmd.step);

    const profile_cmd = b.addRunArtifact(verify_exe);
    profile_cmd.addArg("profile");
    profile_cmd.addPassthruArgs();
    const profile_step = b.step("profile", "Run Complex Repo Benchmark under macOS /usr/bin/sample Call-Stack Profiler");
    profile_step.dependOn(&profile_cmd.step);
}
