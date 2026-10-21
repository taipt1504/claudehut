package demo.cqrs;

/** A framework extension point: generic, one subclass per use case. Not a variant concern. */
public abstract class RequestHandler<Q, R> {
  public abstract R handle(Q query);
}
