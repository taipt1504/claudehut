package com.example.catalog;

import java.util.List;

import org.springframework.stereotype.Service;

@Service
public class ItemService {
    public String describe(long id) {
        return "item-" + id;
    }

    public Status parseStatus(String raw) {
        return StatusConverter.parse(raw);
    }

    public List<String> statusLabels() {
        return StatusConverter.labels();
    }
}
