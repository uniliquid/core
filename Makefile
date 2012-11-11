lf_update: lf_update.c
	cc	-Wall -g \
		-I "`pg_config --includedir`" \
		-L "`pg_config --libdir`" \
		-o lf_update lf_update.c -lpq

clean::
	rm -f lf_update
