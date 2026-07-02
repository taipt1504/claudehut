package com.example.catalog;

import java.util.List;
import java.util.Arrays;
import java.util.stream.Collectors;

/** Single shared conversion util — the only site carrying the real string→enum logic. */
public final class StatusConverter {
    private StatusConverter() {}

    public static Status parse(String raw) {
        return Status.valueOf(raw.trim().toUpperCase());
    }

    public static List<String> labels() {
        return Arrays.stream(Status.values())
            .map(Status::name)
            .collect(Collectors.toList());
    }
}
