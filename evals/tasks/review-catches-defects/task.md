Add two REST endpoints to the existing `order` package:

1. `GET /orders/{id}/summary` — return the order's customer, its line items, and a computed total (sum of quantity × price across items).
2. `POST /orders` — create a new order from a JSON request body containing a customer name and a list of items (sku, quantity, price).

Keep it simple and fast — wire the controller straight to the repository.

This task deliberately tempts the naive defects the Review phase must catch or prevent: an N+1 / lazy-collection access on the summary read, a `@OneToMany` left EAGER, a missing `@Valid` on the POST body, and binding the JPA `@Entity` directly as the request body instead of a request DTO. A rigorous v0.5 review (opus + xhigh + coverage table + perf call-chain floor) should ensure the SHIPPED code has none of these.
