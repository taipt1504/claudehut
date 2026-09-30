package com.x.service;

final class OrderTotals {
    static long safeAdd(long a, long b) {
        return Math.addExact(a, b);
    }
}
