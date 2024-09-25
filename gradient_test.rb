require 'debug'
require 'prawn'
require 'vips'
require_relative 'lib/prawn-svg'

page_width = 1200
page_height = 800

prawn_document = Prawn::Document.new(margin: 0, page_size: [page_width, page_height])

prawn_document.svg(File.read('gradient_test.svg'), width: page_width, height: page_height)

File.write('gradient_test_out.pdf', prawn_document.render)

vips_image = Vips::Image.thumbnail('gradient_test.svg', page_width)
vips_image.pngsave('gradient_test_out_direct.png')

vips_image = Vips::Image.thumbnail('gradient_test_out.pdf', page_width)
vips_image.pngsave('gradient_test_out_via_pdf.png')
