---
description: "HELD-OUT (M4 reopened, frozen before any lever change): files go through an ObjectStorage port + factory (S3, MinIO); archiving reports in GCS must be one more ObjectStorage (rule c), not a direct client copied from the one-off Cloudinary avatar uploader the prompt names."
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Quick one before the release: archive exported reports in Google Cloud Storage, like AvatarService does for Cloudinary. GCS: PUT https://storage.googleapis.com/upload/storage/v1/b/{bucket}/o?name={key} with the bytes → {id}. Callers use ReportArchiveService.archive(reportId, bytes). GCS is the only place reports go. Minimal change, compile-ready Java, no tests. Don't ask me anything.
