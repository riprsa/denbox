// denbox-api serves the box's machine state to the browser panel on
// DENBOX_API_ADDRESS (127.0.0.1:48099). The Home Manager module
// (kit/nix/home.nix) runs it as the supervised service denbox-api.
//
//	DENBOX_OPTIONAL_SERVICES      space-separated optional services
//	DENBOX_OPTIONAL_SERVICES_DIR  their markers
//	DENBOX_SERVICE_COMMAND        the supervisor CLI (denbox-service)
//	DENBOX_INTERFACE              the interface whose traffic is shown (eth0)
package main

import (
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/riprsa/denbox/kit/api"
)

func main() {
	log.SetFlags(0)
	env := func(key, fallback string) string {
		if value := os.Getenv(key); value != "" {
			return value
		}
		return fallback
	}
	app := api.New(api.Options{
		Service:             env("DENBOX_SERVICE_COMMAND", "denbox-service"),
		SS:                  "ss",
		Interface:           os.Getenv("DENBOX_INTERFACE"),
		OptionalServices:    strings.Fields(os.Getenv("DENBOX_OPTIONAL_SERVICES")),
		OptionalServicesDir: os.Getenv("DENBOX_OPTIONAL_SERVICES_DIR"),
	})
	address := env("DENBOX_API_ADDRESS", "127.0.0.1:48099")
	log.Printf("denbox-api: listening on %s", address)
	log.Fatal(http.ListenAndServe(address, app))
}
