run-dev:
	cd frontend && flutter run -d chrome --web-port=5000

run-prod:
	cd frontend && flutter run --dart-define=ENV=.env.prod --web-port=5000
