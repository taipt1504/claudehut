package com.x.entity;

import lombok.Data;

@Data
public class DynamicVaView {
    private String vaNo;
    /** Master account the VA collects into, held raw. */
    private String masterAccountNo;
}
