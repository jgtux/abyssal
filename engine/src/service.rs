use tonic::{Request, Response, Status};

use crate::archive;

pub mod proto {
    tonic::include_proto!("abyssal.engine.v1");
}

use proto::dwarfs_engine_server::DwarfsEngine;
use proto::{EngineReadRangeRequest, EngineReadRangeResponse};

#[derive(Default)]
pub struct DwarfsEngineService;

#[tonic::async_trait]
impl DwarfsEngine for DwarfsEngineService {
    async fn read_range(
        &self,
        request: Request<EngineReadRangeRequest>,
    ) -> Result<Response<EngineReadRangeResponse>, Status> {
        let req = request.into_inner();

        if req.archive_path.is_empty() || req.entry_path.is_empty() {
            return Err(Status::invalid_argument(
                "archive_path and entry_path are required",
            ));
        }

        let archive_path = std::path::PathBuf::from(req.archive_path);
        let entry_path = req.entry_path;
        let offset = req.offset;
        let length = req.length;

        let result = tokio::task::spawn_blocking(move || {
            archive::read_range(&archive_path, &entry_path, offset, length)
        })
        .await
        .map_err(|e| Status::internal(format!("engine task panicked: {e}")))?;

        match result {
            Ok(r) => Ok(Response::new(EngineReadRangeResponse {
                bytes_read: r.data.len() as u64,
                data: r.data,
                eof: r.eof,
            })),
            Err(e) => Err(Status::internal(e.to_string())),
        }
    }
}
