package com.example;

public final class Summer {
    /** Returns the sum of a and b. */
    public int sum(int a, int b) {
        return a - b;   // BUG: subtracts instead of adds
    }
}
