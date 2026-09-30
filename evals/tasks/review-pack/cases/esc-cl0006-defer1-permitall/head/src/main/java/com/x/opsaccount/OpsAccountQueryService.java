package com.x.opsaccount;

public class OpsAccountQueryService {
    public OpsAccountView find(String id) {
        OpsAccountView v = new OpsAccountView(id, null);
        v.guaranteeBankAccountName = lookupGuaranteeName(id);
        return v;
    }
}
