//! Spins up a real DwarfsEngine tonic server on an ephemeral port and
//! issues a real ReadRange RPC against it, proving the gRPC layer end to
//! end (not just the archive.rs internals, which are unit-tested
//! separately).
use std::process::Command;

use tonic::transport::Server;

// The binary crate (abyssal-engine) doesn't expose a lib target, so this
// test re-declares just enough to drive the server directly. If this
// grows, promote src/{archive,service}.rs into a `lib.rs` shared by both
// the binary and this test.
#[path = "../src/archive.rs"]
mod archive;
#[path = "../src/service.rs"]
mod service;

use service::proto::dwarfs_engine_client::DwarfsEngineClient;
use service::proto::dwarfs_engine_server::DwarfsEngineServer;
use service::proto::EngineReadRangeRequest;
use service::DwarfsEngineService;

fn build_fixture() -> Option<(tempfile::TempDir, std::path::PathBuf)> {
    if Command::new("mkdwarfs").arg("--version").output().is_err() {
        eprintln!("skipping: mkdwarfs not on PATH");
        return None;
    }

    let dir = tempfile::tempdir().expect("tempdir");
    let archive_path = dir.path().join("hello.dwarfs");
    let source_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../testdata/hello");

    let status = Command::new("mkdwarfs")
        .arg("-i")
        .arg(&source_dir)
        .arg("-o")
        .arg(&archive_path)
        .status()
        .expect("failed to run mkdwarfs");
    assert!(status.success());

    Some((dir, archive_path))
}

#[tokio::test]
async fn read_range_over_grpc_matches_source_bytes() {
    let Some((_dir, archive_path)) = build_fixture() else {
        return;
    };

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind ephemeral port");
    let addr = listener.local_addr().expect("local_addr");
    let incoming = tokio_stream::wrappers::TcpListenerStream::new(listener);

    tokio::spawn(async move {
        Server::builder()
            .add_service(DwarfsEngineServer::new(DwarfsEngineService))
            .serve_with_incoming(incoming)
            .await
            .expect("server failed");
    });

    // Give the server a moment to start accepting.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let mut client = DwarfsEngineClient::connect(format!("http://{addr}"))
        .await
        .expect("connect");

    let response = client
        .read_range(EngineReadRangeRequest {
            archive_path: archive_path.to_string_lossy().into_owned(),
            entry_path: "hello.txt".to_string(),
            offset: 0,
            length: 11,
        })
        .await
        .expect("read_range RPC")
        .into_inner();

    assert_eq!(response.data, b"hello world");
    assert_eq!(response.bytes_read, 11);
    assert!(response.eof);
}
