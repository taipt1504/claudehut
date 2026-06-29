package com.example.catalog;

import org.springframework.stereotype.Service;

@Service
public class ItemService {
    public String describe(long id) {
        return "item-" + id;
    }
}
