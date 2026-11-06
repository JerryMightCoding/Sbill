use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

use crate::crypto::{
    blake3_hash_b64, canonical_json_bytes, compress_zlib, decompress_zlib_bounded, DeviceKeypair,
    GroupCipher, OPTICAL_PACK_RECOMMENDED_MAX_BYTES, SYNC_PACK_MAX_COMPRESSED_BYTES,
    SYNC_PACK_MAX_DECOMPRESSED_BYTES, SYNC_PACK_MAX_EVENTS,
};
use crate::domain::{EventBody, SignedEvent};
use crate::error::{CoreError, CoreResult};
use crate::storage::{BatchImportSummary, DeviceSyncCursor, LedgerRepository};

pub const TRIPDELTA_MAGIC: &str = "SBILL_TRIPDELTA_V1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TripDeltaPackage {
    pub magic: String,
    pub package_id: String,
    pub group_id: String,
    pub key_epoch: u32,
    pub event_count: usize,
    pub ciphertext_b64: String,
    pub package_digest: String,
}

impl TripDeltaPackage {
    /// Packs a slice of verified `SignedEvent`s by compressing plaintext first, then encrypting
    /// with `GroupCipher` (XChaCha20-Poly1305).
    pub fn pack_events(
        group_id: &str,
        events: &[SignedEvent],
        cipher: &GroupCipher,
    ) -> CoreResult<Self> {
        if events.is_empty() {
            return Err(CoreError::SyncPackage(
                "cannot create an empty TripDeltaPackage".to_string(),
            ));
        }
        if events.len() > SYNC_PACK_MAX_EVENTS {
            return Err(CoreError::LimitExceeded(format!(
                "event count {} exceeds max allowed {}",
                events.len(),
                SYNC_PACK_MAX_EVENTS
            )));
        }
        for ev in events {
            if ev.unsigned.group_id != group_id {
                return Err(CoreError::SyncPackage(format!(
                    "event '{}' belongs to group '{}', expected '{group_id}'",
                    ev.event_id, ev.unsigned.group_id
                )));
            }
            ev.verify_cryptographic_integrity()?;
        }

        let plaintext_bytes = canonical_json_bytes(&events)?;
        if plaintext_bytes.len() > SYNC_PACK_MAX_DECOMPRESSED_BYTES {
            return Err(CoreError::LimitExceeded(format!(
                "uncompressed event batch size {} exceeds {}",
                plaintext_bytes.len(),
                SYNC_PACK_MAX_DECOMPRESSED_BYTES
            )));
        }

        let compressed = compress_zlib(&plaintext_bytes)?;
        let aad = format!("sbill:v1:pack:{}:{}", group_id, cipher.key_epoch());
        let ciphertext = cipher.encrypt(&compressed, aad.as_bytes())?;
        if ciphertext.len() > SYNC_PACK_MAX_COMPRESSED_BYTES {
            return Err(CoreError::LimitExceeded(format!(
                "encrypted sync package size {} exceeds {}",
                ciphertext.len(),
                SYNC_PACK_MAX_COMPRESSED_BYTES
            )));
        }

        let package_id = blake3_hash_b64(&plaintext_bytes);
        let ciphertext_b64 = URL_SAFE_NO_PAD.encode(&ciphertext);
        let mut pkg = Self {
            magic: TRIPDELTA_MAGIC.to_string(),
            package_id,
            group_id: group_id.to_string(),
            key_epoch: cipher.key_epoch(),
            event_count: events.len(),
            ciphertext_b64,
            package_digest: String::new(),
        };
        pkg.package_digest = pkg.compute_digest()?;
        Ok(pkg)
    }

    pub fn unpack_events(&self, expected_group_id: &str, cipher: &GroupCipher) -> CoreResult<Vec<SignedEvent>> {
        if self.magic != TRIPDELTA_MAGIC {
            return Err(CoreError::SyncPackage(format!(
                "unsupported package magic '{}'",
                self.magic
            )));
        }
        if self.group_id != expected_group_id {
            return Err(CoreError::SyncPackage(format!(
                "package group_id '{}' does not match expected '{expected_group_id}'",
                self.group_id
            )));
        }
        if self.event_count == 0 || self.event_count > SYNC_PACK_MAX_EVENTS {
            return Err(CoreError::LimitExceeded(format!(
                "invalid package event_count {}",
                self.event_count
            )));
        }
        let expected_digest = self.compute_digest()?;
        if expected_digest != self.package_digest {
            return Err(CoreError::SyncPackage(
                "TripDeltaPackage digest mismatch (truncated or corrupted file)".to_string(),
            ));
        }

        let ciphertext = URL_SAFE_NO_PAD
            .decode(&self.ciphertext_b64)
            .map_err(|e| CoreError::SyncPackage(format!("invalid ciphertext base64: {e}")))?;
        if ciphertext.len() > SYNC_PACK_MAX_COMPRESSED_BYTES {
            return Err(CoreError::LimitExceeded(
                "ciphertext exceeds max compressed package limit".to_string(),
            ));
        }

        let aad = format!("sbill:v1:pack:{}:{}", self.group_id, self.key_epoch);
        let compressed = cipher.decrypt(&ciphertext, aad.as_bytes())?;
        let decompressed =
            decompress_zlib_bounded(&compressed, SYNC_PACK_MAX_DECOMPRESSED_BYTES)?;

        let events: Vec<SignedEvent> = serde_json::from_slice(&decompressed)
            .map_err(|e| CoreError::SyncPackage(format!("invalid unpacked events JSON: {e}")))?;
        if events.len() != self.event_count {
            return Err(CoreError::SyncPackage(format!(
                "unpacked event count {} does not match header {}",
                events.len(),
                self.event_count
            )));
        }
        for ev in &events {
            ev.verify_cryptographic_integrity()?;
        }
        Ok(events)
    }

    pub fn to_bytes(&self) -> CoreResult<Vec<u8>> {
        canonical_json_bytes(self)
    }

    pub fn from_bytes(bytes: &[u8]) -> CoreResult<Self> {
        if bytes.len() > SYNC_PACK_MAX_COMPRESSED_BYTES + 4096 {
            return Err(CoreError::LimitExceeded(
                "raw .tripdelta file exceeds maximum allowed byte size".to_string(),
            ));
        }
        serde_json::from_slice(bytes)
            .map_err(|e| CoreError::SyncPackage(format!("invalid .tripdelta file format: {e}")))
    }

    fn compute_digest(&self) -> CoreResult<String> {
        let mut clone = self.clone();
        clone.package_digest = String::new();
        let canonical = canonical_json_bytes(&clone)?;
        Ok(blake3_hash_b64(&canonical))
    }
}

/// Summary exchanged during LAN or optical sync handshake so the sender transmits only missing events,
/// including filling mid-stream sequence gaps (AC-L04).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerSyncSummary {
    pub group_id: String,
    pub device_cursors: BTreeMap<String, DeviceSyncCursor>,
    pub known_noncontiguous_event_ids: BTreeSet<String>,
}

impl LedgerRepository {
    pub fn build_sync_summary(&self, group_id: &str) -> CoreResult<PeerSyncSummary> {
        let events = self.list_events(group_id)?;
        if events.is_empty() {
            return Ok(PeerSyncSummary {
                group_id: group_id.to_string(),
                device_cursors: BTreeMap::new(),
                known_noncontiguous_event_ids: BTreeSet::new(),
            });
        }
        let proj = self.project_group(group_id)?;
        let mut noncontiguous = BTreeSet::new();
        for ev in &events {
            if let Some(cursor) = proj.device_cursors.get(&ev.unsigned.device_id) {
                if ev.unsigned.sequence > cursor.contiguous_seq {
                    noncontiguous.insert(ev.event_id.clone());
                }
            }
        }
        Ok(PeerSyncSummary {
            group_id: group_id.to_string(),
            device_cursors: proj.device_cursors,
            known_noncontiguous_event_ids: noncontiguous,
        })
    }

    /// Selects all local events that `peer_summary` is missing (including gap-filling for `missing_seqs`).
    pub fn select_events_missing_on_peer(
        &self,
        group_id: &str,
        peer_summary: &PeerSyncSummary,
    ) -> CoreResult<Vec<SignedEvent>> {
        if peer_summary.group_id != group_id {
            return Err(CoreError::SyncPackage(format!(
                "peer summary group_id '{}' does not match '{group_id}'",
                peer_summary.group_id
            )));
        }
        let all_events = self.list_events(group_id)?;
        let mut delta = Vec::new();
        for ev in all_events {
            match peer_summary.device_cursors.get(&ev.unsigned.device_id) {
                None => delta.push(ev),
                Some(cursor) => {
                    let seq = ev.unsigned.sequence;
                    if seq > cursor.contiguous_seq {
                        if !peer_summary
                            .known_noncontiguous_event_ids
                            .contains(&ev.event_id)
                        {
                            delta.push(ev);
                        }
                    } else if cursor.missing_seqs.contains(&seq) {
                        delta.push(ev);
                    }
                }
            }
        }
        Ok(delta)
    }
}

/// Optical / Animated QR frame supporting both direct slices and XOR fountain parity frames
/// so a receiver can start mid-stream, tolerate dropped frames, and resume the same package (AC-Q01..Q03).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpticalQrFrame {
    pub package_id: String,
    pub total_source_slices: usize,
    pub slice_byte_len: usize,
    pub total_byte_len: usize,
    /// Source slice indices XORed together in `payload_b64` (1 index = direct slice, >=2 = fountain parity).
    pub source_indices: Vec<usize>,
    pub payload_b64: String,
    pub frame_digest: String,
}

impl OpticalQrFrame {
    pub fn verify_frame(&self) -> CoreResult<Vec<u8>> {
        let mut clone = self.clone();
        clone.frame_digest = String::new();
        let expected_digest = blake3_hash_b64(&canonical_json_bytes(&clone)?);
        if expected_digest != self.frame_digest {
            return Err(CoreError::SyncPackage("optical QR frame digest mismatch".to_string()));
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(&self.payload_b64)
            .map_err(|e| CoreError::SyncPackage(format!("invalid QR frame payload base64: {e}")))?;
        if bytes.len() != self.slice_byte_len {
            return Err(CoreError::SyncPackage(
                "QR frame payload length mismatch".to_string(),
            ));
        }
        Ok(bytes)
    }
}

/// Encodes a `TripDeltaPackage` into a sequence of source + fountain parity QR frames.
pub fn encode_optical_fountain_frames(
    pkg: &TripDeltaPackage,
    slice_byte_len: usize,
    parity_frame_count: usize,
) -> CoreResult<Vec<OpticalQrFrame>> {
    if slice_byte_len == 0 || slice_byte_len > 1024 {
        return Err(CoreError::SyncPackage(
            "slice_byte_len must be between 1 and 1024 bytes".to_string(),
        ));
    }
    let raw = pkg.to_bytes()?;
    if raw.len() > OPTICAL_PACK_RECOMMENDED_MAX_BYTES {
        return Err(CoreError::LimitExceeded(format!(
            "optical package size {} exceeds recommended limit {}",
            raw.len(),
            OPTICAL_PACK_RECOMMENDED_MAX_BYTES
        )));
    }

    let total_source_slices = raw.len().div_ceil(slice_byte_len);
    let mut slices: Vec<Vec<u8>> = Vec::with_capacity(total_source_slices);
    for i in 0..total_source_slices {
        let start = i * slice_byte_len;
        let end = ((i + 1) * slice_byte_len).min(raw.len());
        let mut buf = vec![0u8; slice_byte_len];
        buf[..(end - start)].copy_from_slice(&raw[start..end]);
        slices.push(buf);
    }

    let mut frames = Vec::with_capacity(total_source_slices + parity_frame_count);

    // 1. Direct source frames
    for (idx, slice) in slices.iter().enumerate() {
        frames.push(make_optical_frame(
            &pkg.package_id,
            total_source_slices,
            slice_byte_len,
            raw.len(),
            vec![idx],
            slice,
        )?);
    }

    // 2. Deterministic fountain XOR parity frames (each combines 2 or 3 source slices)
    if total_source_slices > 1 {
        for p in 0..parity_frame_count {
            let i1 = p % total_source_slices;
            let i2 = (p * 2 + 1) % total_source_slices;
            let mut indices = BTreeSet::new();
            indices.insert(i1);
            indices.insert(if i2 == i1 { (i1 + 1) % total_source_slices } else { i2 });
            if p % 2 == 1 && total_source_slices >= 3 {
                indices.insert((p * 3 + 2) % total_source_slices);
            }
            let idx_vec: Vec<usize> = indices.into_iter().collect();
            let mut xored = vec![0u8; slice_byte_len];
            for &ix in &idx_vec {
                for (b, &src_b) in xored.iter_mut().zip(slices[ix].iter()) {
                    *b ^= src_b;
                }
            }
            frames.push(make_optical_frame(
                &pkg.package_id,
                total_source_slices,
                slice_byte_len,
                raw.len(),
                idx_vec,
                &xored,
            )?);
        }
    }

    Ok(frames)
}

fn make_optical_frame(
    package_id: &str,
    total_source_slices: usize,
    slice_byte_len: usize,
    total_byte_len: usize,
    source_indices: Vec<usize>,
    payload: &[u8],
) -> CoreResult<OpticalQrFrame> {
    let mut frame = OpticalQrFrame {
        package_id: package_id.to_string(),
        total_source_slices,
        slice_byte_len,
        total_byte_len,
        source_indices,
        payload_b64: URL_SAFE_NO_PAD.encode(payload),
        frame_digest: String::new(),
    };
    frame.frame_digest = blake3_hash_b64(&canonical_json_bytes(&frame)?);
    Ok(frame)
}

/// Peeling decoder for `OpticalQrFrame`s that caches progress by `package_id`
/// and isolates fragments if a new `package_id` is scanned (AC-Q02, AC-Q03).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpticalFountainAssembler {
    active_package_id: Option<String>,
    total_source_slices: usize,
    slice_byte_len: usize,
    total_byte_len: usize,
    solved_slices: BTreeMap<usize, Vec<u8>>,
    pending_equations: Vec<(BTreeSet<usize>, Vec<u8>)>,
}

impl Default for OpticalFountainAssembler {
    fn default() -> Self {
        Self::new()
    }
}

impl OpticalFountainAssembler {
    pub fn new() -> Self {
        Self {
            active_package_id: None,
            total_source_slices: 0,
            slice_byte_len: 0,
            total_byte_len: 0,
            solved_slices: BTreeMap::new(),
            pending_equations: Vec::new(),
        }
    }

    pub fn active_package_id(&self) -> Option<&str> {
        self.active_package_id.as_deref()
    }

    pub fn progress(&self) -> (usize, usize) {
        (self.solved_slices.len(), self.total_source_slices)
    }

    /// Feeds one scanned QR frame. Automatically resets if `frame.package_id` switches to a different package.
    /// Returns `Ok(Some(TripDeltaPackage))` once all source slices are recovered.
    pub fn ingest_frame(&mut self, frame: &OpticalQrFrame) -> CoreResult<Option<TripDeltaPackage>> {
        let data = frame.verify_frame()?;
        if frame.total_byte_len > OPTICAL_PACK_RECOMMENDED_MAX_BYTES
            || frame.total_source_slices == 0
            || frame.total_source_slices > 2048
        {
            return Err(CoreError::LimitExceeded(
                "optical QR frame declares excessive slice or byte dimensions".to_string(),
            ));
        }

        if self.active_package_id.as_deref() != Some(frame.package_id.as_str()) {
            self.active_package_id = Some(frame.package_id.clone());
            self.total_source_slices = frame.total_source_slices;
            self.slice_byte_len = frame.slice_byte_len;
            self.total_byte_len = frame.total_byte_len;
            self.solved_slices.clear();
            self.pending_equations.clear();
        }

        let mut indices: BTreeSet<usize> = frame.source_indices.iter().copied().collect();
        let mut rhs = data;

        // Eliminate already-solved variables
        for (&solved_idx, solved_bytes) in &self.solved_slices {
            if indices.remove(&solved_idx) {
                for (b, &sb) in rhs.iter_mut().zip(solved_bytes.iter()) {
                    *b ^= sb;
                }
            }
        }

        if !indices.is_empty() {
            self.pending_equations.push((indices, rhs));
            self.propagate_peeling();
        }

        if self.solved_slices.len() == self.total_source_slices {
            let mut full_bytes = Vec::with_capacity(self.total_source_slices * self.slice_byte_len);
            for idx in 0..self.total_source_slices {
                full_bytes.extend_from_slice(&self.solved_slices[&idx]);
            }
            full_bytes.truncate(self.total_byte_len);
            let pkg = TripDeltaPackage::from_bytes(&full_bytes)?;
            return Ok(Some(pkg));
        }

        Ok(None)
    }

    fn propagate_peeling(&mut self) {
        loop {
            let single_pos = self
                .pending_equations
                .iter()
                .position(|(idxs, _)| idxs.len() == 1);
            let Some(pos) = single_pos else {
                break;
            };
            let (idxs, rhs) = self.pending_equations.swap_remove(pos);
            let solved_idx = *idxs.iter().next().unwrap();
            if self.solved_slices.contains_key(&solved_idx) {
                continue;
            }
            self.solved_slices.insert(solved_idx, rhs.clone());

            for (eq_idxs, eq_rhs) in &mut self.pending_equations {
                if eq_idxs.remove(&solved_idx) {
                    for (b, &sb) in eq_rhs.iter_mut().zip(rhs.iter()) {
                        *b ^= sb;
                    }
                }
            }
            self.pending_equations.retain(|(eq_idxs, _)| !eq_idxs.is_empty());
        }
    }
}

/// Abstract WebDAV encrypted object store interface so unit tests, local NAS mocks,
/// and production HTTPS WebDAV clients share the exact same synchronization logic.
pub trait WebDavRemoteStore {
    fn put_encrypted_object(
        &mut self,
        opaque_group_dir: &str,
        object_hash: &str,
        ciphertext: &[u8],
    ) -> CoreResult<()>;

    fn list_encrypted_objects(&self, opaque_group_dir: &str) -> CoreResult<Vec<String>>;

    fn get_encrypted_object(
        &self,
        opaque_group_dir: &str,
        object_hash: &str,
    ) -> CoreResult<Vec<u8>>;
}

/// In-memory WebDAV store implementation for deterministic testing and fault injection.
#[derive(Default, Clone)]
pub struct InMemoryWebDavStore {
    objects: BTreeMap<(String, String), Vec<u8>>,
    pub fail_writes: bool,
}

impl InMemoryWebDavStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Test helper to simulate server-side tampering of an encrypted object (AC-D05).
    pub fn tamper_object(&mut self, opaque_group_dir: &str, object_hash: &str) {
        if let Some(bytes) = self
            .objects
            .get_mut(&(opaque_group_dir.to_string(), object_hash.to_string()))
        {
            if let Some(last) = bytes.last_mut() {
                *last ^= 0xFF;
            }
        }
    }
}

impl WebDavRemoteStore for InMemoryWebDavStore {
    fn put_encrypted_object(
        &mut self,
        opaque_group_dir: &str,
        object_hash: &str,
        ciphertext: &[u8],
    ) -> CoreResult<()> {
        if self.fail_writes {
            return Err(CoreError::SyncPackage(
                "WebDAV remote unreachable or write rejected".to_string(),
            ));
        }
        self.objects
            .entry((opaque_group_dir.to_string(), object_hash.to_string()))
            .or_insert_with(|| ciphertext.to_vec());
        Ok(())
    }

    fn list_encrypted_objects(&self, opaque_group_dir: &str) -> CoreResult<Vec<String>> {
        Ok(self
            .objects
            .keys()
            .filter(|(g, _)| g == opaque_group_dir)
            .map(|(_, h)| h.clone())
            .collect())
    }

    fn get_encrypted_object(
        &self,
        opaque_group_dir: &str,
        object_hash: &str,
    ) -> CoreResult<Vec<u8>> {
        self.objects
            .get(&(opaque_group_dir.to_string(), object_hash.to_string()))
            .cloned()
            .ok_or_else(|| CoreError::NotFound(format!("WebDAV object '{object_hash}' not found")))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebDavSyncReport {
    pub uploaded_objects: usize,
    pub failed_uploads: usize,
    pub downloaded_events: usize,
    pub duplicate_events: usize,
    pub tampered_or_rejected_objects: usize,
}

pub fn opaque_group_directory_id(group_id: &str) -> String {
    blake3_hash_b64(format!("sbill:webdav:dir:{group_id}").as_bytes())
}

/// Synchronizes a local `LedgerRepository` with a `WebDavRemoteStore` (push outbox + pull new objects).
pub fn sync_with_webdav(
    repo: &mut LedgerRepository,
    group_id: &str,
    cipher: &GroupCipher,
    remote: &mut dyn WebDavRemoteStore,
) -> CoreResult<WebDavSyncReport> {
    let dir = opaque_group_directory_id(group_id);
    let pending = repo.pending_webdav_uploads(group_id)?;
    let mut uploaded_objects = 0usize;
    let mut failed_uploads = 0usize;

    for (object_hash, _event_id, ciphertext) in pending {
        match remote.put_encrypted_object(&dir, &object_hash, &ciphertext) {
            Ok(()) => {
                repo.mark_webdav_uploaded(&object_hash)?;
                uploaded_objects += 1;
            }
            Err(_) => {
                let _ = repo.record_webdav_retry(&object_hash)?;
                failed_uploads += 1;
            }
        }
    }

    let remote_hashes = remote.list_encrypted_objects(&dir)?;
    let aad = format!("sbill:v1:event:{group_id}");
    let mut decoded_events = Vec::new();
    let mut tampered_or_rejected = 0usize;

    for hash in remote_hashes {
        let Ok(ciphertext) = remote.get_encrypted_object(&dir, &hash) else {
            tampered_or_rejected += 1;
            continue;
        };
        if blake3_hash_b64(&ciphertext) != hash {
            tampered_or_rejected += 1;
            continue;
        }
        let Ok(plaintext) = cipher.decrypt(&ciphertext, aad.as_bytes()) else {
            tampered_or_rejected += 1;
            continue;
        };
        let Ok(ev) = serde_json::from_slice::<SignedEvent>(&plaintext) else {
            tampered_or_rejected += 1;
            continue;
        };
        if ev.verify_cryptographic_integrity().is_err() {
            tampered_or_rejected += 1;
            continue;
        }
        decoded_events.push(ev);
    }

    // Events pulled from WebDAV are already stored on WebDAV; pass `None` so they are not re-queued into `webdav_outbox`.
    let import_summary: BatchImportSummary =
        repo.import_event_batch(group_id, &decoded_events, None)?;
    tampered_or_rejected += import_summary.rejected_events.len();

    Ok(WebDavSyncReport {
        uploaded_objects,
        failed_uploads,
        downloaded_events: import_summary.added_count,
        duplicate_events: import_summary.duplicate_count,
        tampered_or_rejected_objects: tampered_or_rejected,
    })
}

const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
const SBILL_PNG_CHUNK_TYPE: [u8; 4] = *b"sbIl";

/// Embeds a `TripDeltaPackage` into a valid lossless PNG file inside a custom ancillary chunk `sbIl`
/// (`FR-SYNC-05`, `AC-I01`).
pub fn embed_tripdelta_into_png(pkg: &TripDeltaPackage) -> CoreResult<Vec<u8>> {
    let payload = pkg.to_bytes()?;
    let mut out = Vec::with_capacity(64 + payload.len());
    out.extend_from_slice(&PNG_SIGNATURE);

    // 1x1 RGB IHDR chunk
    let ihdr_data: [u8; 13] = [
        0, 0, 0, 1, // width = 1
        0, 0, 0, 1, // height = 1
        8, // bit depth = 8
        2, // color type = RGB
        0, 0, 0,
    ];
    write_png_chunk(&mut out, *b"IHDR", &ihdr_data);

    // Custom private ancillary chunk `sbIl` carrying the encrypted `.tripdelta` package
    write_png_chunk(&mut out, SBILL_PNG_CHUNK_TYPE, &payload);

    // Minimal IDAT chunk
    let idat_data = compress_zlib(&[0u8, 15, 118, 110])?;
    write_png_chunk(&mut out, *b"IDAT", &idat_data);

    // IEND chunk
    write_png_chunk(&mut out, *b"IEND", &[]);
    Ok(out)
}

/// Extracts a `TripDeltaPackage` from an original PNG carrier file (`AC-I01`),
/// or returns an explicit diagnostic error if the image was converted to JPEG, screenshot,
/// or stripped of metadata (`AC-I02`).
pub fn extract_tripdelta_from_png(image_bytes: &[u8]) -> CoreResult<TripDeltaPackage> {
    if image_bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Err(CoreError::SyncPackage(
            "同步数据缺失：图片已被重压缩为 JPEG 格式，请发送原文件或 .tripdelta 同步包 (AC-I02)"
                .to_string(),
        ));
    }
    if image_bytes.len() < 8 || image_bytes[..8] != PNG_SIGNATURE {
        return Err(CoreError::SyncPackage(
            "不是有效的 PNG 原图文件，请发送原文件 (.tripdelta)".to_string(),
        ));
    }

    let mut pos = 8usize;
    while pos + 12 <= image_bytes.len() {
        let len = u32::from_be_bytes(image_bytes[pos..pos + 4].try_into().unwrap()) as usize;
        let chunk_type: [u8; 4] = image_bytes[pos + 4..pos + 8].try_into().unwrap();
        let data_start = pos + 8;
        let data_end = data_start.saturating_add(len);
        if data_end + 4 > image_bytes.len() {
            return Err(CoreError::SyncPackage(
                "PNG 文件被截断，无法提取同步数据".to_string(),
            ));
        }
        let chunk_data = &image_bytes[data_start..data_end];
        let expected_crc =
            u32::from_be_bytes(image_bytes[data_end..data_end + 4].try_into().unwrap());
        let actual_crc = crc32_ieee(&chunk_type, chunk_data);
        if expected_crc != actual_crc {
            return Err(CoreError::SyncPackage(
                "PNG 数据块 CRC 校验失败，文件已损坏".to_string(),
            ));
        }
        if chunk_type == SBILL_PNG_CHUNK_TYPE {
            return TripDeltaPackage::from_bytes(chunk_data);
        }
        pos = data_end + 4;
    }

    Err(CoreError::SyncPackage(
        "同步数据缺失：该 PNG 图片不包含 sbill 同步数据块（可能为截图或已被相册清除元数据），请发送原文件 (AC-I02)"
            .to_string(),
    ))
}

fn write_png_chunk(out: &mut Vec<u8>, chunk_type: [u8; 4], data: &[u8]) {
    let len = data.len() as u32;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(&chunk_type);
    out.extend_from_slice(data);
    let crc = crc32_ieee(&chunk_type, data);
    out.extend_from_slice(&crc.to_be_bytes());
}

fn crc32_ieee(chunk_type: &[u8; 4], data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in chunk_type.iter().chain(data.iter()) {
        crc ^= u32::from(b);
        for _ in 0..8 {
            if (crc & 1) != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    !crc
}

/// Encrypted backup of a member's personal Ed25519 signing key protected by a personal passphrase
/// (and NEVER by the shared group key, so other group members cannot impersonate them: `FR-BKP-01`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemberIdentityBackup {
    #[serde(default = "legacy_backup_version")]
    pub format_version: u32,
    #[serde(default)]
    pub kdf: String,
    pub member_id: String,
    pub device_id: String,
    pub public_key_b64: String,
    pub salt_b64: String,
    pub encrypted_secret_b64: String,
}

const IDENTITY_BACKUP_KDF: &str = "argon2id-v19-m65536-t3-p1";
fn legacy_backup_version() -> u32 { 1 }

impl MemberIdentityBackup {
    pub fn create(
        member_id: &str,
        device_id: &str,
        keypair: &DeviceKeypair,
        passphrase: &str,
    ) -> CoreResult<Self> {
        use rand::RngCore;
        use zeroize::Zeroize;
        let mut salt = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut salt);
        let mut backup = Self {
            format_version: 2, kdf: IDENTITY_BACKUP_KDF.into(),
            member_id: member_id.into(), device_id: device_id.into(),
            public_key_b64: keypair.public_key_b64(), salt_b64: URL_SAFE_NO_PAD.encode(salt),
            encrypted_secret_b64: String::new(),
        };
        let mut derived_key = derive_passphrase_key(passphrase, &backup.salt_b64)?;
        let cipher = GroupCipher::from_raw(derived_key, 1);
        derived_key.zeroize();
        let secret = zeroize::Zeroizing::new(keypair.secret_bytes());
        let encrypted = cipher.encrypt(secret.as_ref(), &backup.authenticated_metadata()?);
        backup.encrypted_secret_b64 = URL_SAFE_NO_PAD.encode(encrypted?);
        Ok(backup)
    }

    pub fn restore(&self, passphrase: &str) -> CoreResult<DeviceKeypair> {
        use zeroize::Zeroize;
        if self.format_version != 2 || self.kdf != IDENTITY_BACKUP_KDF ||
            self.member_id.len() > 200 || self.device_id.len() > 200 ||
            self.public_key_b64.len() != 43 || self.encrypted_secret_b64.len() > 128 {
            return Err(CoreError::Crypto("备份版本或参数不支持；旧弱口令格式请在原设备重新导出".into()));
        }
        let mut derived_key = derive_passphrase_key(passphrase, &self.salt_b64)?;
        let cipher = GroupCipher::from_raw(derived_key, 1);
        derived_key.zeroize();
        let ct = URL_SAFE_NO_PAD
            .decode(&self.encrypted_secret_b64)
            .map_err(|e| CoreError::Crypto(format!("invalid backup ciphertext base64: {e}")))?;
        let mut secret = cipher.decrypt(&ct, &self.authenticated_metadata()?).map_err(|_| {
            CoreError::Crypto("恢复口令错误或备份已损坏，无法恢复成员签名私钥".to_string())
        })?;
        let mut arr: [u8; 32] = match secret.as_slice().try_into() {
            Ok(value) => value,
            Err(_) => { secret.zeroize(); return Err(CoreError::Crypto("restored secret must be 32 bytes".into())); }
        };
        secret.zeroize();
        let kp = DeviceKeypair::from_secret_bytes(&arr);
        arr.zeroize();
        if kp.public_key_b64() != self.public_key_b64 {
            return Err(CoreError::Crypto(
                "restored keypair public key mismatch".to_string(),
            ));
        }
        Ok(kp)
    }

    fn authenticated_metadata(&self) -> CoreResult<Vec<u8>> {
        if self.member_id.is_empty() || self.device_id.is_empty() ||
            self.member_id.len() > 200 || self.device_id.len() > 200 {
            return Err(CoreError::Crypto("无效的备份身份标识".into()));
        }
        crate::crypto::canonical_json_bytes(&serde_json::json!({
            "domain": "sbill:identity-backup:v2", "format_version": self.format_version,
            "kdf": self.kdf, "member_id": self.member_id, "device_id": self.device_id,
            "public_key_b64": self.public_key_b64, "salt_b64": self.salt_b64,
        }))
    }
}

fn derive_passphrase_key(passphrase: &str, salt: &str) -> CoreResult<[u8; 32]> {
    if passphrase.chars().count() < 12 || passphrase.len() > 1024 || passphrase.trim().is_empty() {
        return Err(CoreError::Crypto("恢复口令须至少 12 个字符，最多 1024 字节".into()));
    }
    if salt.len() != 43 { return Err(CoreError::Crypto("无效的恢复盐值".into())); }
    let salt_bytes = URL_SAFE_NO_PAD.decode(salt).map_err(|_| CoreError::Crypto("无效恢复盐值".into()))?;
    if salt_bytes.len() != 32 { return Err(CoreError::Crypto("恢复盐值须为32字节".into())); }
    let parameters = argon2::Params::new(65536, 3, 1, Some(32))
        .map_err(|e| CoreError::Crypto(e.to_string()))?;
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, parameters);
    let mut key = [0u8; 32];
    argon.hash_password_into(passphrase.as_bytes(), &salt_bytes, &mut key)
        .map_err(|e| CoreError::Crypto(e.to_string()))?;
    Ok(key)
}

/// Diagnostic report after device migration or backup restoration (`AC-B02`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestoreCompletenessReport {
    pub group_id: String,
    pub total_events_restored: usize,
    pub group_cipher_available: bool,
    pub member_signing_key_restored: bool,
    pub missing_attachment_ids: Vec<String>,
    pub requires_owner_device_authorization: bool,
}

pub fn evaluate_restore_completeness(
    repo: &LedgerRepository,
    group_id: &str,
    member_id: &str,
    restored_keypair: Option<&DeviceKeypair>,
    group_cipher_available: bool,
) -> CoreResult<RestoreCompletenessReport> {
    let events = repo.list_events(group_id)?;
    let proj = repo.project_group(group_id)?;

    let mut missing_attachment_ids = Vec::new();
    for ev in &events {
        if let EventBody::ExpenseUpsert(exp) = &ev.unsigned.body {
            for att in &exp.attachment_refs {
                if !repo.has_attachment(group_id, &att.attachment_id)? {
                    missing_attachment_ids.push(att.attachment_id.clone());
                }
            }
        }
    }

    let expected_pk = proj
        .active_policy
        .participants
        .get(member_id)
        .and_then(|p| p.bound_public_key.as_deref());
    let signing_key_matches = match (restored_keypair, expected_pk) {
        (Some(kp), Some(pk)) => kp.public_key_b64() == pk,
        _ => false,
    };

    Ok(RestoreCompletenessReport {
        group_id: group_id.to_string(),
        total_events_restored: events.len(),
        group_cipher_available,
        member_signing_key_restored: signing_key_matches,
        missing_attachment_ids,
        requires_owner_device_authorization: !signing_key_matches,
    })
}
