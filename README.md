# Abyssal

Immutable, compressed dataset storage built on **ZFS** and **DwarFS**.

Abyssal packages large directory trees into immutable dataset artifacts (such as `.dwarfs`) stored on ZFS pools, combining aggressive compression with strong integrity guarantees.

The system focuses on **reproducible datasets**, efficient storage usage, and predictable performance when working with very large data collections.

---

# Getting Started

Abyssal is two services plus a shared gRPC contract:

- `manager/` — Elixir. Dataset lifecycle, the external API, ZFS monitoring
  (extends [jgtux/grpc-zfs-monitor-demo](https://github.com/jgtux/grpc-zfs-monitor-demo)).
- `engine/` — Rust. Links against [tamatebako/libdwarfs](https://github.com/tamatebako/libdwarfs)
  (a C wrapper over [mhx/dwarfs](https://github.com/mhx/dwarfs)) to read DwarFS archives directly.
- `proto/` — the gRPC contracts both sides generate code from.

```sh
# One-time: build libdwarfs-wr (native, multi-minute build)
git submodule update --init
engine/scripts/build-libdwarfs.sh

# Terminal 1: the Rust engine
cd engine && cargo run

# Terminal 2: the Elixir manager
cd manager && mix deps.get && mix run --no-halt

# Terminal 3: the CLI, driving both over gRPC
cd manager && mix escript.build && ./abyssal demo
```

`demo` publishes `testdata/hello/` as a dataset, reads a byte range back out
of the resulting `.dwarfs` archive through the full stack, and compares it
against the source file. `demo --encrypt` runs the same check against an
encrypted dataset, verifying the raw key, recovery phrase, and Shamir
shares each independently decrypt correctly — see Encryption below.

---

# Philosophy

Abyssal is built around a few core principles.

## Immutability

Datasets are published as immutable artifacts.
Once a dataset version is published, it cannot be modified.

This enables:

- reproducible experiments
- deterministic pipelines
- safe replication
- efficient caching

## Compression-first storage

Datasets are packaged using **DwarFS**, enabling strong compression and deduplication-like benefits across similar files.

ZFS may optionally apply additional compression depending on the selected storage strategy.

## Integrity over convenience

ZFS provides strong guarantees for storage integrity.

Key mechanisms include:

- end-to-end checksums
- ARC / L2ARC caching
- background scrubbing
- snapshotting
- replication

Abyssal treats ZFS as the **source of truth for storage reliability**.

---

# Architecture

Abyssal separates the system into several logical layers.

```
Application / Client
        │
        ▼
Abyssal Manager
        │
        ▼
Filesystem Access Layer
(VFS → FUSE → DwarFS)
        │
        ▼
ZFS Storage Layer
(checksums, ARC cache, snapshots)
        │
        ▼
      Disk
```

In this architecture:

- **DwarFS** exposes compressed datasets as filesystems
- **ZFS** provides integrity, caching, and storage management
- **Abyssal** orchestrates dataset lifecycle and publishing

---

# Dataset Lifecycle

A dataset goes through several stages before it becomes available.

```
Raw dataset
    │
    ▼
Artifact build
(DwarFS packaging)
    │
    ▼
Published artifact
(.dwarfs + manifest)
    │
    ▼
Stored in ZFS releases dataset
    │
    ▼
Consumed through mount or API
```

Artifacts are immutable once published.

---

# Encryption

Dataset encryption is **opt-in** (`publish --encrypt`) and per-dataset: each
publish generates its own random AES-256-GCM key, and the whole `.dwarfs`
archive is encrypted at rest under that key.

The manager never stores keys. At publish time it prints the raw key once —
save it, or one of the recovery forms below, or the dataset becomes
unreadable:

- **Recovery phrase** — a 24-word BIP39-style mnemonic encoding the key
  directly (no PBKDF2 stretching; this recovers one fixed key, not a wallet
  seed tree).
- **Key splitting** — Shamir's Secret Sharing, k-of-n threshold (default
  3-of-5). Any `k` of the `n` shares reconstruct the key; fewer than `k`
  reveal nothing about it.

Recovery isn't a separate "disaster" code path — every `read-range` call
supplies key material in one of three equivalent forms (`--key`,
`--phrase`, or `--shares`), and the manager resolves whichever was given
down to the raw key before asking the engine to decrypt. A wrong key, a
mistyped phrase, and an insufficient set of shares are all caught the same
way: the engine's AES-GCM authentication tag fails and the read is
rejected.

```sh
./abyssal publish --name mydata --version v1 --source ./data \
  --encrypt --recovery both --shamir-threshold 3 --shamir-shares 5

./abyssal read-range --name mydata --version v1 --entry file.txt \
  --offset 0 --length 100 --key <hex from publish>

./abyssal recover-key --shares <share1> --shares <share2> --shares <share3>
```

---

# Post-Quantum Cryptography

AES-256-GCM remains secure against quantum computers (Grover's algorithm reduces its effective security to 128 bits — still safe). The risk is **key distribution**: a quantum attacker who captures a dataset key today could decrypt the archive later. PQC hardens the key layer without touching the performant AES-GCM data path.

## ML-KEM key wrapping

When a key must leave the engine — shared with a collaborator, backed up to a remote vault, or stored in a manifest — wrap it under ML-KEM-768 instead of exposing the raw AES key.

```sh
./abyssal publish --name mydata --version v1 --source ./data \
  --encrypt --kem-wrap --recovery both --shamir-threshold 3 --shamir-shares 5
```

The AES key is encrypted to an ephemeral ML-KEM public key. The ML-KEM secret key is split via Shamir's Secret Sharing (default 3-of-5). To read, a caller reconstructs the ML-KEM secret from shares, decapsulates the AES key, and decrypts as usual.

```sh
./abyssal read-range --name mydata --version v1 --entry file.txt \
  --offset 0 --length 100 --kem-shares <s1> --kem-shares <s2> --kem-shares <s3>
```

## Hybrid mode (recommended during transition)

Combine X25519 + ML-KEM-768 via HKDF so that breaking either primitive alone is insufficient:

$$K_{\text{final}} = \text{HKDF-SHA-256}(K_{\text{X25519}} \parallel K_{\text{ML-KEM-768}} \parallel \text{context})$$

Enable with `--hybrid-kem`.

## ML-DSA manifest signatures

Sign the dataset manifest at publish time to prove provenance and prevent manifest tampering.

```sh
./abyssal publish --name mydata --version v1 --source ./data \
  --encrypt --sign --identity-key ~/.abyssal/id_ml-dsa-65
```

```sh
./abyssal read-range --name mydata --version v1 --entry file.txt \
  --verify --identity-key <publisher-pubkey> \
  --kem-shares <s1> --kem-shares <s2> --kem-shares <s3>
```

ML-DSA-65 (NIST Level 3) produces ~3.3 KB signatures stored in the manifest, not per-block.

## Recovery phrases

PQC-aware recovery extends the existing BIP39 mnemonic to encode both the AES key and the ML-KEM secret key seed, or derives both deterministically from a single master seed via HKDF. One phrase still recovers everything.

## Migration

| Phase | Action |
|-------|--------|
| Now | Audit where AES keys are transmitted or stored outside the engine |
| Next | Add `--kem-wrap` and `--hybrid-kem` options |
| Later | Add `--sign` / `--verify` for manifest provenance |
| Post-2030 | Make PQC wrapping the default |

PQC fields in the manifest are optional — older clients ignore them and fall back to legacy key material.

---

# Compression Profiles

Abyssal allows selecting compression strategies when publishing datasets.

Profiles define how artifacts are built and how they are stored.

## Hot

Optimized for **read throughput and low CPU overhead**.

- **DwarFS:** fast compression (`zstd` low or medium)
- **ZFS:** `lz4` or disabled

Best for:

- frequently accessed datasets
- ML training workloads
- active research environments

This profile prioritizes **fast decompression and minimal read latency**.

## Balanced

General-purpose profile providing **good compression with moderate CPU cost**.

- **DwarFS:** `zstd` medium compression
- **ZFS:** `lz4`

Best for:

- regularly accessed datasets
- internal research data
- most production workloads

Balanced is intended to be the **default profile**, offering a compromise between storage efficiency and read performance.

## Archive

Optimized for **maximum storage efficiency**.

- **DwarFS:** aggressive compression (`zstd` high or optionally `lzma`)
- **ZFS:** compression disabled or `lz4`

Best for:

- rarely accessed datasets
- historical archives
- long-term storage

Using **LZMA** can significantly reduce dataset size but increases decompression time and CPU usage.  
It is therefore recommended only for datasets that are **rarely accessed**.

---

# Dynamic Compression Behavior

When storage pools approach capacity, Abyssal can adjust compression strategies for new dataset publications.

Example policy:

```
Pool usage < 70% → balanced profile
Pool usage > 70% → stronger compression
Pool usage > 85% → archive profile
```

Existing artifacts remain immutable, but new releases can be generated with stronger compression settings.

---

# Access Modes

Abyssal supports two ways of accessing datasets.

## Mounted mode

Datasets are mounted via **FUSE + DwarFS**.

Applications can use normal filesystem operations:

```
/mnt/abyssal/mydataset/
```

Best for:

- POSIX tools
- scripts
- compatibility

## On-demand mode (planned)

Datasets are accessed via API (gRPC / HTTP range reads). The client retrieves only the required portions of the dataset.

Advantages:

- avoids filesystem metadata overhead
- efficient remote access
- better control over caching

---

# Observability

Abyssal aims to expose operational metrics for monitoring and performance analysis.

Potential metrics include:

- read operations per second
- dataset access frequency
- compression ratios
- ARC cache hit ratio
- storage pool usage
- latency statistics

These metrics can be integrated with systems such as:

- Prometheus
- Grafana

---

# Storage Maintenance

Recommended operational practices include:

- periodic **ZFS scrubs**
- monitoring pool health (SMART + `zpool status`)
- replication using `zfs send` / `zfs receive`
- dataset retention policies

---

# Project Status

Abyssal is currently in **early experimental development**.

Working today: publish a directory as a dataset (via `mkdwarfs`) and read a
byte range back out of it, end to end through the Elixir manager and Rust
engine, over gRPC — see Getting Started above. Optional per-dataset
encryption (AES-256-GCM) with recovery via a BIP39-style phrase and/or
Shamir's Secret Sharing — see Encryption above. Compression profiles
(Hot/Balanced/Archive) can be selected explicitly per publish, or left to
the dynamic pool-capacity-based policy — see Compression Profiles and
Dynamic Compression Behavior above.

Not yet built: real ZFS pool integration (the release store is a plain
directory for now), the FUSE mounted-mode access path, retention/replication.

Current focus areas:

- DwarFS + FUSE performance testing
- compression strategy evaluation
- dataset artifact lifecycle design
- integration with ZFS

---

# License

This project is licensed under the **BSD-3 Clause license**.

See the `LICENSE` file for full details.

---

# Logo Concept

Planned logo:

A **bacteriophage-inspired creature** with subtle abyssal horns, referencing the FreeBSD Beastie while evoking a deep-storage organism that attaches to datasets.
