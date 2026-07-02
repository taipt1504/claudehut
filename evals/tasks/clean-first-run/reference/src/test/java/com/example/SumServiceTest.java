package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;
import org.junit.jupiter.api.Test;

class SumServiceTest {
    @Test
    void sumsIntegers() {
        assertEquals(6, new SumService().sum(List.of(1, 2, 3)));
    }
}
