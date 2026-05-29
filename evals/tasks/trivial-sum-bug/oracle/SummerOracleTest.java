package com.example;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

class SummerOracleTest {
    @Test void addsPositives()  { assertEquals(5,  new Summer().sum(2, 3)); }
    @Test void addsToZero()     { assertEquals(0,  new Summer().sum(-1, 1)); }
    @Test void addsNegatives()  { assertEquals(-7, new Summer().sum(-3, -4)); }
}
