package node

import (
	panel "github.com/fsh2502/v2nodePro/api/v2board"
	"github.com/fsh2502/v2nodePro/common/certificate"
	log "github.com/sirupsen/logrus"
)

func (c *Controller) certificateReportingEnabled() bool {
	return c.info.Common.BaseConfig != nil && c.info.Common.BaseConfig.CertificateReport
}

func (c *Controller) captureCertificate() {
	if !c.certificateReportingEnabled() || c.info.Security != panel.Tls {
		return
	}
	cert := c.info.Common.CertInfo
	if cert == nil || cert.CertMode == "" || cert.CertMode == "none" {
		return
	}
	// Only a successfully started controller will report this snapshot.
	c.loadedCertificate, _ = certificate.Read(cert.CertFile, cert.KeyFile)
}

func (c *Controller) reportCertificateTask() error {
	if !c.certificateReportingEnabled() {
		return nil
	}
	report := panel.CertificateReport{Revision: c.info.Common.BaseConfig.CertificateRevision}
	cert := c.info.Common.CertInfo
	if c.info.Security == panel.Tls && cert != nil && cert.CertMode != "" && cert.CertMode != "none" {
		current, err := certificate.Read(cert.CertFile, cert.KeyFile)
		if err != nil {
			log.WithField("tag", c.tag).Warn("Cannot read TLS key pair; keeping last reported certificate")
			return nil
		}
		if c.loadedCertificate == nil || current.SHA256 != c.loadedCertificate.SHA256 {
			// Xray polls files on its own schedule. Reload before publishing a new
			// pin, including certificates renewed by an external ACME client.
			if c.server.ReloadCh != nil {
				select {
				case c.server.ReloadCh <- struct{}{}:
				default:
				}
			}
			return nil
		}
		report.TLSEnabled = true
		report.SHA256 = current.SHA256
		report.PublicKeySHA256 = current.PublicKeySHA256
		report.NotAfter = current.NotAfter
		report.Issuer = current.Issuer
	}
	if err := c.apiClient.ReportCertificate(report); err != nil {
		log.WithField("tag", c.tag).Warn(err)
	}
	// Reporting failures do not stop the node or traffic accounting.
	return nil
}
