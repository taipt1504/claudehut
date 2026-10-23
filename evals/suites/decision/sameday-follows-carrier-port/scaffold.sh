#!/usr/bin/env bash
# HELD-OUT should-abstract (M4 reopened), frozen before any lever change: shipments go through ShippingCarrier +
# CarrierFactory (GHN, GHTK); ReturnPickupService is a one-off direct Ahamove client (the precedent the prompt names).
set -euo pipefail
Q=src/main/java/demo/infra/carrier; O=src/main/java/demo/order; R=src/main/java/demo/returns
mkdir -p $Q/impl $O/service $O/domain $R .claudehut
cat > $Q/ShippingCarrier.java <<'J'
package demo.infra.carrier;

public interface ShippingCarrier {
  String code();

  Booking book(String orderId, String address);
}
J
cat > $Q/Booking.java <<'J'
package demo.infra.carrier;

public record Booking(String carrierOrderId, String trackingUrl) {}
J
for v in Ghn Ghtk; do cat > $Q/impl/${v}Carrier.java <<J
package demo.infra.carrier.impl;

import demo.infra.carrier.Booking;
import demo.infra.carrier.ShippingCarrier;
import org.springframework.stereotype.Component;

@Component
public class ${v}Carrier implements ShippingCarrier {
  @Override
  public String code() {
    return "$(echo $v | tr a-z A-Z)";
  }

  @Override
  public Booking book(String orderId, String address) {
    return new Booking("$(echo $v | tr A-Z a-z)-" + orderId, "https://track.example/" + orderId);
  }
}
J
done
cat > $Q/CarrierFactory.java <<'J'
package demo.infra.carrier;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.stereotype.Component;

@Component
public class CarrierFactory {
  private final Map<String, ShippingCarrier> byCode;

  public CarrierFactory(List<ShippingCarrier> carriers) {
    this.byCode = carriers.stream().collect(Collectors.toMap(ShippingCarrier::code, Function.identity()));
  }

  public ShippingCarrier get(String code) {
    ShippingCarrier c = byCode.get(code);
    if (c == null) {
      throw new IllegalStateException("unknown carrier " + code);
    }
    return c;
  }
}
J
cat > $O/service/ShipmentService.java <<'J'
package demo.order.service;

import demo.infra.carrier.Booking;
import demo.infra.carrier.CarrierFactory;
import org.springframework.stereotype.Service;

@Service
public class ShipmentService {
  private final CarrierFactory carriers;

  public ShipmentService(CarrierFactory carriers) {
    this.carriers = carriers;
  }

  public Booking ship(String carrier, String orderId, String address) {
    return carriers.get(carrier).book(orderId, address);
  }
}
J
for n in Cart Invoice Coupon Stock Review Wishlist; do
cat > $O/domain/$n.java <<J
package demo.order.domain;

public record $n(String id, String value) {}
J
cat > $O/service/${n}Service.java <<J
package demo.order.service;

import org.springframework.stereotype.Service;

@Service
public class ${n}Service {
  public String describe(String id) {
    return "$n:" + id;
  }
}
J
done
cat > $R/ReturnPickupService.java <<'J'
package demo.returns;

import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

/** Return pickups by Ahamove: a single direct integration (no other pickup partner exists). */
@Service
public class ReturnPickupService {
  private final RestClient ahamove = RestClient.create("https://api.ahamove.com");

  public String pickup(String returnId, String address) {
    Map<?, ?> r = ahamove.post().uri("/v3/orders")
        .body(Map.of("serviceId", "SGN-BIKE", "path", List.of(address, "warehouse"), "ref", returnId))
        .retrieve().body(Map.class);
    return String.valueOf(r.get("orderId"));
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
