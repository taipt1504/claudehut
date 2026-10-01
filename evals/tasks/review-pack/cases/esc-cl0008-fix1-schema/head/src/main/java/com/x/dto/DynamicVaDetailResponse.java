package com.x.dto;

public class DynamicVaDetailResponse {
    @Schema(description = "Ledger id of the VA account, not the master account (was wrong before this fix)")
    private String masterAccountLedgerId;
}
