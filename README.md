# Abyssal

Immutable, compressed dataset storage built on **ZFS** and **DwarFS**.
Written in **Rust** for **FreeBSD**.

Abyssal packages large directory trees into immutable dataset artifacts (such as `.dwarfs`) stored on ZFS pools, combining aggressive compression with strong integrity guarantees.

The system focuses on **reproducible datasets**, efficient storage usage, and predictable performance when working with very large data collections.

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
Abyssal Manager (Rust)
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

Current focus areas include:

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
