//go:build windows

package main

import (
	"log"
	"os"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const svcName = "PCInfoBackend"

// runService corre como servicio de Windows cuando lo arranca el SCM (sin
// ventana de consola y como LocalSystem → smartctl tiene acceso a los discos).
// Si el binario se ejecuta a mano o lo lanza la GUI (dev/portátil), corre como
// un proceso normal.
func runService(addr string) {
	isSvc, err := svc.IsWindowsService()
	if err != nil || !isSvc {
		runServer(addr)
		return
	}
	if err := svc.Run(svcName, &pcinfoService{addr: addr}); err != nil {
		log.Printf("servicio: %v", err)
	}
}

type pcinfoService struct{ addr string }

func (s *pcinfoService) Execute(_ []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	const accepts = svc.AcceptStop | svc.AcceptShutdown
	changes <- svc.Status{State: svc.StartPending}
	go runServer(s.addr)
	changes <- svc.Status{State: svc.Running, Accepts: accepts}
	for c := range r {
		switch c.Cmd {
		case svc.Interrogate:
			changes <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			changes <- svc.Status{State: svc.StopPending}
			return false, 0
		default:
		}
	}
	return false, 0
}

// handleServiceControl atiende los subcomandos que usa el instalador: instalar,
// desinstalar, iniciar y detener el servicio. Devuelve true si atendió alguno.
func handleServiceControl(cmd, addr string) bool {
	switch cmd {
	case "install":
		if err := installService(addr); err != nil {
			log.Printf("install: %v", err)
			os.Exit(1)
		}
	case "uninstall":
		if err := removeService(); err != nil {
			log.Printf("uninstall: %v", err)
			os.Exit(1)
		}
	case "start":
		if err := startService(); err != nil {
			log.Printf("start: %v", err)
			os.Exit(1)
		}
	case "stop":
		if err := stopService(); err != nil {
			log.Printf("stop: %v", err)
			os.Exit(1)
		}
	default:
		return false
	}
	return true
}

func installService(addr string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()

	// Si ya existe (reinstalación), lo recreamos para tomar el binario nuevo.
	if s, err := m.OpenService(svcName); err == nil {
		s.Control(svc.Stop)
		s.Delete()
		s.Close()
	}

	s, err := m.CreateService(svcName, exe, mgr.Config{
		DisplayName:  "PCInfo Backend",
		Description:  "Servicio de inventario de hardware de PCInfo.",
		StartType:    mgr.StartAutomatic,
		ErrorControl: mgr.ErrorNormal,
	}, "--addr", addr)
	if err != nil {
		return err
	}
	defer s.Close()
	return s.Start()
}

func removeService() error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()

	s, err := m.OpenService(svcName)
	if err != nil {
		return nil // no existe: nada que hacer
	}
	defer s.Close()
	s.Control(svc.Stop)
	return s.Delete()
}

func startService() error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(svcName)
	if err != nil {
		return err
	}
	defer s.Close()
	return s.Start()
}

func stopService() error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(svcName)
	if err != nil {
		return nil
	}
	defer s.Close()
	_, err = s.Control(svc.Stop)
	return err
}
