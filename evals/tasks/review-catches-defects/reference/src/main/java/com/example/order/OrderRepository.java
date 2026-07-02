package com.example.order;

import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface OrderRepository extends JpaRepository<Order, Long> {

  // Single-query load of order + its items (join fetch) — avoids the N+1 on the summary read.
  @Query("select o from Order o join fetch o.items where o.id = :id")
  Optional<Order> findWithItemsById(@Param("id") Long id);
}
