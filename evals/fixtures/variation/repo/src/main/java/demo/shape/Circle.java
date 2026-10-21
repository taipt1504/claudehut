package demo.shape;

public record Circle(double size) implements Shape {
  public double area() {
    return size * size;
  }
}
