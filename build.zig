const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libtb32 = b.dependency("tb32", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tb32hv",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tb32", libtb32.module("tb32"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tb32hv");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("tb32", libtb32.module("tb32"));
    const test_step = b.step("test", "Run tb32hv tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // wasm shim: the HV + guest kernel compiled to wasm32 with browser/node exports.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const libtb32_wasm = b.dependency("tb32", .{ .target = wasm_target, .optimize = .ReleaseSmall });
    const wasm = b.addExecutable(.{
        .name = "tb32hv",
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm.root_module.addImport("tb32", libtb32_wasm.module("tb32"));
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } });
    const wasm_step = b.step("wasm", "Build the wasm shim (tb32hv.wasm)");
    wasm_step.dependOn(&wasm_install.step);
}
