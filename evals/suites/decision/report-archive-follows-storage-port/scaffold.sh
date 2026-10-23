#!/usr/bin/env bash
# HELD-OUT should-abstract (M4 reopened), frozen before any lever change: object storage goes through ObjectStorage +
# ObjectStorageFactory (S3, MinIO); AvatarService is a one-off direct Cloudinary client (the precedent the prompt names).
set -euo pipefail
Q=src/main/java/demo/infra/storage; F=src/main/java/demo/files; A=src/main/java/demo/profile
mkdir -p $Q/impl $F/service $F/domain $A .claudehut
cat > $Q/ObjectStorage.java <<'J'
package demo.infra.storage;

public interface ObjectStorage {
  String code();

  StoredObject put(String key, byte[] bytes);
}
J
cat > $Q/StoredObject.java <<'J'
package demo.infra.storage;

public record StoredObject(String key, String storageId) {}
J
for v in S3 Minio; do cat > $Q/impl/${v}ObjectStorage.java <<J
package demo.infra.storage.impl;

import demo.infra.storage.ObjectStorage;
import demo.infra.storage.StoredObject;
import org.springframework.stereotype.Component;

@Component
public class ${v}ObjectStorage implements ObjectStorage {
  @Override
  public String code() {
    return "$(echo $v | tr a-z A-Z)";
  }

  @Override
  public StoredObject put(String key, byte[] bytes) {
    return new StoredObject(key, "$(echo $v | tr A-Z a-z)-" + key.hashCode());
  }
}
J
done
cat > $Q/ObjectStorageFactory.java <<'J'
package demo.infra.storage;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
public class ObjectStorageFactory {
  private final Map<String, ObjectStorage> byCode;
  private final String active;

  public ObjectStorageFactory(List<ObjectStorage> storages, @Value("${storage.active:S3}") String active) {
    this.byCode = storages.stream().collect(Collectors.toMap(ObjectStorage::code, Function.identity()));
    this.active = active;
  }

  public ObjectStorage get(String code) {
    ObjectStorage s = byCode.get(code);
    if (s == null) {
      throw new IllegalStateException("unknown storage " + code);
    }
    return s;
  }

  public ObjectStorage active() {
    return get(active);
  }
}
J
cat > $F/service/DocumentService.java <<'J'
package demo.files.service;

import demo.infra.storage.ObjectStorageFactory;
import demo.infra.storage.StoredObject;
import org.springframework.stereotype.Service;

@Service
public class DocumentService {
  private final ObjectStorageFactory storages;

  public DocumentService(ObjectStorageFactory storages) {
    this.storages = storages;
  }

  public StoredObject store(String documentId, byte[] bytes) {
    return storages.active().put("documents/" + documentId, bytes);
  }
}
J
for n in Folder Tag Owner Quota Retention Checksum; do
cat > $F/domain/$n.java <<J
package demo.files.domain;

public record $n(String id, String value) {}
J
cat > $F/service/${n}Service.java <<J
package demo.files.service;

import org.springframework.stereotype.Service;

@Service
public class ${n}Service {
  public String describe(String id) {
    return "$n:" + id;
  }
}
J
done
cat > $A/AvatarService.java <<'J'
package demo.profile;

import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

/** Avatars go to Cloudinary: a single direct integration (images are resized there). */
@Service
public class AvatarService {
  private final RestClient cloudinary = RestClient.create("https://api.cloudinary.com");

  public String upload(String userId, byte[] image) {
    Map<?, ?> r = cloudinary.post().uri("/v1_1/demo/image/upload").body(image).retrieve().body(Map.class);
    return String.valueOf(r.get("public_id"));
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
