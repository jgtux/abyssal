use tonic::{Request, Response, Status};

use crate::archive::{self, EngineError};

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
        let key = req.key;

        let result = tokio::task::spawn_blocking(move || {
            let key = if key.is_empty() {
                None
            } else {
                Some(key.as_slice())
            };
            archive::read_range(&archive_path, &entry_path, offset, length, key)
        })
        .await
        .map_err(|e| Status::internal(format!("engine task panicked: {e}")))?;

        match result {
            Ok(r) => Ok(Response::new(EngineReadRangeResponse {
                bytes_read: r.data.len() as u64,
                data: r.data,
                eof: r.eof,
            })),
            // MissingKey/InvalidKey are the client's fault (didn't supply
            // key material, or supplied a malformed one) -- invalid_argument.
            // DecryptFailed is deliberately its own status (permission_denied):
            // "wrong key" is a meaningfully different operator message than
            // "you forgot to supply one", and AES-GCM can't tell us whether
            // it was a wrong key or a tampered archive, so we don't
            // over-claim either. CorruptArchive means the file is too short
            // to even contain a valid header -- data_loss. Every other
            // variant keeps its existing generic internal mapping.
            Err(EngineError::MissingKey) => Err(Status::invalid_argument(
                "archive is encrypted; key material required",
            )),
            Err(EngineError::InvalidKey) => {
                Err(Status::invalid_argument("key must be exactly 32 bytes"))
            }
            Err(EngineError::DecryptFailed) => Err(Status::permission_denied(
                "decryption failed: wrong key or corrupted archive",
            )),
            Err(EngineError::CorruptArchive) => {
                Err(Status::data_loss("encrypted archive header is malformed"))
            }
            Err(EngineError::LengthTooLarge) => Err(Status::invalid_argument(
                EngineError::LengthTooLarge.to_string(),
            )),
            Err(e) => Err(Status::internal(e.to_string())),
        }
    }
}
