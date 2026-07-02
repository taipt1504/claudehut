package com.example;

import java.util.List;

public class SumService {
    public int sum(List<Integer> values) {
        int total = 0;
        for (Integer v : values) {
            total += v;
        }
        return total;
    }
}
