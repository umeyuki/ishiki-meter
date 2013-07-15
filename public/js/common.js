$(function() {
    $('tr[data-href]').addClass('clickable')
        .click(function(e) {
            if(!$(e.target).is('a')){
                window.location = $(e.target).closest('tr').data('href');
            };
        });
});

function noty_generate(layout,text) {
  	var n = noty({
  		text: text,
  		type: 'warning',
        dismissQueue: true,
  		layout: layout,
  		theme: 'defaultTheme'
  	});
}
