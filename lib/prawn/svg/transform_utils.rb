module Prawn::SVG::TransformUtils
  def load_matrix(matrix)
    if matrix.is_a?(Matrix) && matrix.row_count == 3 && matrix.column_count == 3
      matrix
    elsif matrix.is_a?(Array) && matrix.length == 6
      Matrix[
        [matrix[0], matrix[2], matrix[4]],
        [matrix[1], matrix[3], matrix[5]],
        [0.0, 0.0, 1.0]
      ]
    else
      raise ArgumentError, 'unexpected matrix format'
    end
  end

  def matrix_for_pdf(matrix)
    matrix.to_a[0..1].transpose.flatten
  end
end
