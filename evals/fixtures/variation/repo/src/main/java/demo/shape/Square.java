package demo.shape;

public record Square(double size) implements Shape {
  public double area() {
    return size * size;
  }
}
