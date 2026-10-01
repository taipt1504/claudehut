package com.x.config;

class InternalRoutes {
    void routes(Http http) {
        http.path("/internal/**").permitAll();
    }
}
