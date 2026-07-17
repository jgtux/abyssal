mod archive;
mod config;
mod service;

use tonic::transport::Server;

use config::Config;
use service::proto::dwarfs_engine_server::DwarfsEngineServer;
use service::DwarfsEngineService;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let config = Config::from_env();
    tracing::info!(addr = %config.listen_addr, "starting abyssal-engine");

    Server::builder()
        .add_service(DwarfsEngineServer::new(DwarfsEngineService))
        .serve(config.listen_addr)
        .await?;

    Ok(())
}
