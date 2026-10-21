package demo.user;

import org.springframework.stereotype.Service;

@Service
public class UserServiceImpl implements UserService {
  public String name(String id) {
    return id;
  }
}
