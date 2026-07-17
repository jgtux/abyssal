fn main() {
    // build_client(true) even though the binary itself never calls out as
    // a client -- tests/engine_integration.rs needs the generated client
    // stub to drive the server over a real gRPC connection.
    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&["../proto/abyssal/engine/v1/engine.proto"], &["../proto"])
        .expect("failed to compile engine.proto");
}
