package demo.user;

/** N1: an interface with ONE implementation is not a variation point. */
public interface UserService {
  String name(String id);
}
