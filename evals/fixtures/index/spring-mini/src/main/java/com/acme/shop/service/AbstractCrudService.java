package com.acme.shop.service;

import org.springframework.data.r2dbc.repository.R2dbcRepository;

/** Negative probe: a type parameter bounded by R2dbcRepository is not a repository. */
public abstract class AbstractCrudService<E, ID, R extends R2dbcRepository<E, ID>> {

  protected R repository;
}
