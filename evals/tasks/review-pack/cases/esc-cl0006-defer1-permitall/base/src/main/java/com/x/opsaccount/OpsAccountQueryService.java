package com.x.opsaccount;

public class OpsAccountQueryService {
    public OpsAccountView find(String id) {
        return new OpsAccountView(id, null);
    }
}
